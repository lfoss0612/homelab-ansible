#!/bin/bash
#
# Report kernel OOM-killer activity to Zabbix as a trapper count + a text
# summary of the most recent kill, via zabbix_sender.
#
# Surfaced 2026-08-27: the kernel OOM-killer killed VM 105 (k8s-worker) on
# pve.home.lan on 2026-08-24 20:00:07 -- anon-rss:24524056kB, essentially its
# whole declared 24G. Nothing alerted, before or after: pve.home.lan carries no
# memory trigger at all (only pve-ai's does, from the Proxmox VE template), and
# there was no OOM-specific check anywhere. The VM auto-recovered and the node
# rejoined the cluster looking healthy, so the only record of a real production
# incident was this host's own kernel log.
#
# ---------------------------------------------------------------------------
# Deliberately NOT `set -e`, same reasoning as smart-monitor.sh: a monitor must
# never exit early on the very condition it exists to report.
# ---------------------------------------------------------------------------

set -uo pipefail

ZABBIX_SERVER="${ZABBIX_SERVER:-10.0.5.9}"
ZABBIX_PORT="${ZABBIX_PORT:-10051}"

# Same list, same reasoning as smart-monitor.sh: a value sent under the wrong
# host name is accepted by the server and silently discarded, and hardcoding
# one agent config path is exactly what killed the fleet-update notifier when
# the fleet moved from agent1 to agent2.
ZABBIX_CONFS="${ZABBIX_CONFS:-/etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf}"

CURSOR_FILE="${OOM_CURSOR_FILE:-/var/lib/oom-kill-monitor/cursor}"

WORK_DIR=$(mktemp -d) || exit 1
BATCH="$WORK_DIR/batch"
: > "$BATCH"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '%s\n' "$*" >&2; }

resolve_hostname() {
	local conf name
	if [ -n "${ZABBIX_HOSTNAME:-}" ]; then
		printf '%s' "$ZABBIX_HOSTNAME"
		return
	fi
	for conf in $ZABBIX_CONFS; do
		[ -r "$conf" ] || continue
		name=$(sed -n 's/^[[:space:]]*Hostname=[[:space:]]*//p' "$conf" | tail -1)
		if [ -n "$name" ]; then
			printf '%s' "$name"
			return
		fi
	done
	hostname -f
}

queue() { printf -- '- %s %s\n' "$1" "$2" >> "$BATCH"; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

mkdir -p "$(dirname "$CURSOR_FILE")"

# First run: seed the cursor to the current tail instead of the start of the
# journal. Without this, installing the monitor on a host with an OLD OOM
# event in its journal (like pve's, from 2026-08-24) would replay it as a
# brand-new alert the moment the timer first fires -- confusing, and not what
# "monitoring" means here. journalctl -n0 --show-cursor emits only the cursor
# for the current tail, no lines.
if [ ! -s "$CURSOR_FILE" ]; then
	if journalctl -k -n0 --show-cursor 2>"$WORK_DIR/seed.err" \
		| sed -n 's/^-- cursor: //p' > "$CURSOR_FILE.tmp"; then
		mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
		log "First run: seeded cursor to current tail, skipping any pre-existing OOM history."
	else
		log "WARNING: could not seed journal cursor: $(cat "$WORK_DIR/seed.err")"
		rm -f "$CURSOR_FILE.tmp"
	fi
fi

# --- read new journal entries since the last run -----------------------------
#
# -o short-iso so each line carries its own timestamp; nothing below indexes
# fields by POSITION (only by matching literal tokens like "process" or
# "anon-rss:"), so the leading timestamp doesn't shift anything.
JOURNAL_ERR="$WORK_DIR/journal.err"
if [ -s "$CURSOR_FILE" ]; then
	journalctl -k -o short-iso --after-cursor="$(cat "$CURSOR_FILE")" --show-cursor \
		> "$WORK_DIR/journal.out" 2>"$JOURNAL_ERR"
	JOURNAL_RC=$?
else
	# Seeding failed above; read nothing new rather than dumping full history.
	: > "$WORK_DIR/journal.out"
	JOURNAL_RC=0
fi

if [ "$JOURNAL_RC" -ne 0 ]; then
	# Most likely cause: the cursor points into journal that has since been
	# rotated/vacuumed away. Re-seed to the current tail so next run recovers,
	# rather than failing forever on a cursor that can never be found again.
	log "WARNING: journalctl failed reading from stored cursor: $(cat "$JOURNAL_ERR")"
	log "         Re-seeding cursor to current tail; some events may be missed."
	journalctl -k -n0 --show-cursor 2>/dev/null \
		| sed -n 's/^-- cursor: //p' > "$CURSOR_FILE.tmp" \
		&& mv "$CURSOR_FILE.tmp" "$CURSOR_FILE"
fi

# Advance the cursor to what we just read, regardless of whether it contained
# a match -- an OOM-kill line does not carry its own end-of-batch marker, so
# "-- cursor: ..." (journalctl's own trailer) is the only reliable stopping
# point. Extracted before the awk pass below strips it back out.
NEW_CURSOR=$(sed -n 's/^-- cursor: //p' "$WORK_DIR/journal.out" | tail -1)

# --- find kills, pairing each with the cgroup named on the preceding
#     oom-kill: summary line so a `kvm` process can be traced to a VMID -------
#
# Plain POSIX awk only (no gawk match()/array-capture): mawk, not gawk, is
# Debian's default `awk`, and the earlier SMART script already had to learn
# this the hard way with `command -v` under the wrong module. Every field is
# found by searching tokens, not by position, so this survives minor kernel
# message format drift across versions.
COUNT=0
LAST_EVENT=""
if [ -s "$WORK_DIR/journal.out" ]; then
	while IFS= read -r line; do
		case "$line" in
			*task_memcg=*)
				# NOT split on whitespace like the fields below: the real line has
				# no spaces at all in this section --
				#   ...cpuset=qemu.slice,mems_allowed=0,global_oom,task_memcg=/qemu.slice/105.scope,task=kvm,pid=5487,uid=0
				# -- so task_memcg= is buried mid-field, comma-delimited, not its
				# own awk field. Verified live 2026-08-27: the field-splitting
				# version above silently found nothing and every event reported
				# memcg=unknown. sed substring capture instead, stopping at the
				# next comma.
				LAST_MEMCG=$(printf '%s\n' "$line" | sed -n 's/.*task_memcg=\([^,]*\).*/\1/p')
				;;
			*"Out of memory: Killed process"*)
				read -r TS PID COMM RSS_KB <<-EOF
					$(printf '%s\n' "$line" | awk '{
						pid=""; comm=""; rss=""
						for (i=1;i<=NF;i++) {
							if ($i=="process") pid=$(i+1)
							if ($i ~ /^\(.*\)$/ && comm=="") { c=$i; gsub(/[()]/,"",c); comm=c }
							if ($i ~ /^anon-rss:/) { split($i,a,":"); r=a[2]; gsub(/[^0-9]/,"",r); rss=r }
						}
						print $1, (pid==""?"?":pid), (comm==""?"?":comm), (rss==""?"0":rss)
					}')
				EOF
				RSS_GB=$(awk -v kb="$RSS_KB" 'BEGIN{printf "%.1f", kb/1048576}')
				COUNT=$((COUNT + 1))
				LAST_EVENT="$TS pid=$PID comm=$COMM rss=${RSS_GB}G memcg=${LAST_MEMCG:-unknown}"
				;;
		esac
	done < "$WORK_DIR/journal.out"
fi

if [ -n "$NEW_CURSOR" ]; then
	printf '%s\n' "$NEW_CURSOR" > "$CURSOR_FILE"
fi

ZABBIX_HOST=$(resolve_hostname)

queue "system.oom.count" "$COUNT"
if [ "$COUNT" -gt 0 ]; then
	log "OOM-killer fired $COUNT time(s): $LAST_EVENT"
	queue "system.oom.last_event" "\"$(json_escape "$LAST_EVENT")\""
else
	log "No new OOM-killer activity."
fi

if ! command -v zabbix_sender >/dev/null 2>&1; then
	log "zabbix_sender not installed — skipping the Zabbix push"
	exit 1
fi

# Same "the server accepts the connection but can silently discard every
# value" trap as smart-monitor.sh -- read the counters back rather than
# trusting the exit status.
sender_out=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$ZABBIX_HOST" -i "$BATCH" 2>&1)
log "zabbix_sender: $sender_out"

case "$sender_out" in
	*"failed: 0"*) ;;
	*)
		log "WARNING: Zabbix discarded values sent as host '$ZABBIX_HOST'."
		log "         Run playbooks/oom-kill-monitor-zabbix-setup.yml, or check that"
		log "         Hostname= in the agent config matches the Zabbix host name."
		;;
esac

# Exit status reflects the push, not what was found: an OOM-kill is a normal,
# expected thing to REPORT, not a monitor failure.
exit 0
