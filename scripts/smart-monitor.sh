#!/bin/bash
#
# Report SMART drive health to Zabbix as low-level discovery + trapper values.
#
# Sends one discovery payload (smart.discovery) plus per-drive and aggregate
# values, all in a single zabbix_sender batch. Server-side objects are created
# by playbooks/smart-monitor-zabbix-setup.yml; see docs/smart-monitoring.md.
#
# ---------------------------------------------------------------------------
# Deliberately NOT `set -e`.
#
# The version this replaces was, and it combined that with a check_drive() that
# returned non-zero for an unhealthy drive. Two consequences, both verified
# against the live API on 2026-08-25 rather than reasoned about:
#
#   1. `grep -q FAILED` matched the WHEN_FAILED *column header* present in every
#      healthy ATA report, so every drive looked unhealthy and returned 1;
#   2. under `set -e` that bare call aborted the whole script at the FIRST drive.
#
# Net effect: only the first drive in scan order ever reported, and `smart.status`
# -- sent after the loop -- had never once been collected on any host, in the
# three days the timer had been running. A monitoring script must never exit
# early on the very condition it exists to report, so failures here are counted,
# not fatal.
# ---------------------------------------------------------------------------

set -uo pipefail

ZABBIX_SERVER="${ZABBIX_SERVER:-10.0.5.9}"
ZABBIX_PORT="${ZABBIX_PORT:-10051}"

# Tried in order, purely to learn the Hostname= this machine is known by in
# Zabbix: a value sent under the wrong name is accepted by the server and then
# silently discarded. This is a LIST rather than a path on purpose -- a single
# hardcoded /etc/zabbix/zabbix_agentd.conf is what killed the fleet-update
# notifier when the fleet moved to agent2, and all four SMART hosts run agent2.
ZABBIX_CONFS="${ZABBIX_CONFS:-/etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf}"

# Overall status, worst-of across drives: 0 ok, 1 failing, 2 unreadable.
#
# 1 OUTRANKS 2, which is not the numeric order -- the same convention
# openclaw-fleet-update already uses for its per-host roll-up ("1 = task
# failures, 2 = unreachable; 1 outranks 2 outranks 0"). Ranking numerically
# instead masks the more serious condition: a host with one dying disk and one
# unreadable disk would report 2, firing only the Warning-level "unreadable"
# trigger while the High-level "a drive is failing" trigger stayed silent.
# Tracked as two flags rather than a running max so the precedence is explicit.
ANY_FAILING=0
ANY_UNREADABLE=0
DRIVE_COUNT=0

WORK_DIR=$(mktemp -d) || exit 1
BATCH="$WORK_DIR/batch"
REPORT="$WORK_DIR/report"
: > "$BATCH"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '%s\n' "$*" >&2; }

# Never use bash's own $HOSTNAME here: in an interactive shell it is the SHORT
# name, while Zabbix knows these hosts by FQDN.
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

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

queue() { printf -- '- %s %s\n' "$1" "$2" >> "$BATCH"; }

# --- per-drive collection ---------------------------------------------------
#
# smartctl --scan reports a -d type, but it is NOT passed through to -a here.
# On pve the scan calls the SATA drives `-d scsi`, and forcing that yields the
# SCSI report with no ATA attribute table at all; letting smartctl auto-detect
# gives the ATA table those drives really have. Drive class is therefore taken
# from the report's own content below, never from the scan line.
check_drive() {
	local dev="$1"
	local short="${dev##*/}"
	local out="$WORK_DIR/$short.txt"
	local class status temp failed model

	if ! smartctl -a "$dev" > "$out" 2>&1; then
		# Non-zero is normal for smartctl -- its exit status is a bitmask and
		# bits 2..7 flag things like a populated error log on an otherwise
		# healthy drive. Only treat it as unreadable if we also got no usable
		# health line out of it.
		if ! grep -qE 'self-assessment test result|SMART Health Status' "$out"; then
			log "ERROR: smartctl could not read $dev"
			queue "smart.drive[$short,status]" 2
			ANY_UNREADABLE=1
			printf '%s\tunreadable\t-\t-\n' "$short" >> "$REPORT"
			# Still discovered, deliberately. A drive that cannot be read needs
			# its items to EXIST so the status=2 above lands somewhere and can be
			# alerted on; dropping it from discovery would send that value to a
			# nonexistent item and the server would discard it silently.
			printf '{"{#DEV}":"%s","{#TYPE}":"unknown","{#MODEL}":"unreadable"}\n' \
				"$(json_escape "$short")" >> "$WORK_DIR/lld"
			DRIVE_COUNT=$((DRIVE_COUNT + 1))
			return
		fi
	fi

	if grep -q 'NVMe Version\|Number of Namespaces' "$out"; then
		class=nvme
	else
		class=ata
	fi

	model=$(grep -m1 -E '^(Device Model|Model Number):' "$out" | sed 's/^[^:]*:[[:space:]]*//')
	[ -n "$model" ] || model="unknown"

	# Health verdict. PASSED/FAILED covers ATA and NVMe; SCSI drives use a
	# different sentence, so both are matched.
	if grep -q 'self-assessment test result: PASSED' "$out" || grep -q 'SMART Health Status: OK' "$out"; then
		status=0
	elif grep -q 'self-assessment test result: FAILED' "$out" || grep -qE 'SMART Health Status: [^O]' "$out"; then
		status=1
	else
		status=2
	fi

	# Temperature. The two report formats have nothing in common:
	#   ATA  ->  194 Temperature_Celsius  0x0002  138 138 000 Old_age Always - 47 (Min/Max 23/51)
	#   NVMe ->  Temperature:  62 Celsius
	# The old regex ('\d+\s*$' against the ATA line) matched neither -- the ATA
	# line ends in ')' and NVMe has no Temperature_Celsius attribute at all --
	# which is why temperature had never collected on a single drive.
	temp=""
	if [ "$class" = nvme ]; then
		temp=$(awk '/^Temperature:/ {print $2; exit}' "$out")
	else
		temp=$(awk '$2 == "Temperature_Celsius" || $2 == "Airflow_Temperature_Cel" {print $10; exit}' "$out")
	fi
	# Guard against the odd firmware that reports a non-numeric or absurd value.
	if ! [[ "$temp" =~ ^[0-9]+$ ]] || [ "$temp" -gt 150 ]; then
		temp=""
	fi

	# Failed attributes. Column 9 (WHEN_FAILED) is '-' on a healthy ATA drive;
	# anything else names the point at which the attribute went below threshold.
	# Matching the bare word FAILED here -- as the old script did -- also matched
	# the WHEN_FAILED header itself, flagging every healthy drive.
	if [ "$class" = nvme ]; then
		local warn media
		warn=$(awk -F: '/^Critical Warning:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$out")
		media=$(awk -F: '/^Media and Data Integrity Errors:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$out")
		failed=0
		[ -n "$warn" ] && [ "$warn" != "0x00" ] && failed=1
		[ -n "$media" ] && [ "$media" -gt 0 ] 2>/dev/null && failed=1
	else
		failed=$(awk 'NF >= 10 && $1 ~ /^[0-9]+$/ && $9 != "-" {n++} END {print n+0}' "$out")
		[ "$failed" -gt 0 ] && failed=1
	fi

	# Worst-of roll-up. Written as plain ifs rather than a && / || chain: the
	# chained form reads as one condition but binds left-to-right, which is an
	# easy way to silently lose a case.
	if [ "$status" -eq 1 ] || [ "$failed" -eq 1 ]; then
		ANY_FAILING=1
	fi
	if [ "$status" -eq 2 ]; then
		ANY_UNREADABLE=1
	fi

	queue "smart.drive[$short,status]" "$status"
	queue "smart.drive[$short,failed_attrs]" "$failed"
	if [ -n "$temp" ]; then
		queue "smart.drive[$short,temperature]" "$temp"
	fi

	printf '%s\t%s\t%s\t%s\n' "$short" "$status" "${temp:--}" "$failed" >> "$REPORT"
	printf '{"{#DEV}":"%s","{#TYPE}":"%s","{#MODEL}":"%s"}\n' \
		"$(json_escape "$short")" "$class" "$(json_escape "$model")" >> "$WORK_DIR/lld"
	DRIVE_COUNT=$((DRIVE_COUNT + 1))
}

# --- main -------------------------------------------------------------------

ZABBIX_HOST=$(resolve_hostname)
: > "$REPORT"
: > "$WORK_DIR/lld"

if ! command -v smartctl >/dev/null 2>&1; then
	log "smartctl not installed — nothing to report"
	exit 1
fi

mapfile -t DRIVES < <(smartctl --scan 2>/dev/null | awk '/^\/dev\// {print $1}')

for dev in "${DRIVES[@]}"; do
	[ -n "$dev" ] || continue
	check_drive "$dev"
done

if [ "$DRIVE_COUNT" -eq 0 ]; then
	# Distinct from "all healthy": a host that has stopped seeing its disks is
	# the most alarming state of all, and 0 drives must never look like 0 faults.
	log "WARNING: no drives detected by smartctl"
	ANY_UNREADABLE=1
fi

# Precedence, not maximum. See the ANY_FAILING comment at the top.
if [ "$ANY_FAILING" -eq 1 ]; then
	OVERALL_STATUS=1
elif [ "$ANY_UNREADABLE" -eq 1 ]; then
	OVERALL_STATUS=2
else
	OVERALL_STATUS=0
fi

# One JSON object per line above, joined here. Building the commas inside the
# loop instead would emit a stray separator for any drive that returned early,
# producing malformed JSON that Zabbix rejects as a whole -- losing discovery for
# every OTHER drive because one was unreadable.
queue "smart.discovery" "[$(paste -sd, "$WORK_DIR/lld")]"
queue "smart.drives.count" "$DRIVE_COUNT"
queue "smart.status" "$OVERALL_STATUS"

column -t "$REPORT" 2>/dev/null || cat "$REPORT"
echo "host=$ZABBIX_HOST drives=$DRIVE_COUNT overall=$OVERALL_STATUS"

if ! command -v zabbix_sender >/dev/null 2>&1; then
	log "zabbix_sender not installed — skipping the Zabbix push"
	exit 1
fi

# The server reports success for the CONNECTION even when it throws every value
# away for want of a matching item, so the counters have to be read back rather
# than trusting the exit status. Same failure mode the fleet-update notifier hit.
sender_out=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$ZABBIX_HOST" -i "$BATCH" 2>&1)
log "zabbix_sender: $sender_out"

case "$sender_out" in
	*"failed: 0"*) ;;
	*)
		log "WARNING: Zabbix discarded values sent as host '$ZABBIX_HOST'."
		log "         Run playbooks/smart-monitor-zabbix-setup.yml, or check that"
		log "         Hostname= in the agent config matches the Zabbix host name."
		;;
esac

# Exit status reflects the push, not drive health: a failing drive is a normal,
# expected outcome to REPORT, and marking the systemd unit failed for it would
# bury a genuinely broken monitor among routine disk alerts.
exit 0
