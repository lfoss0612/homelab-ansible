#!/bin/bash
#
# Report CPU sensor temperatures to Zabbix as low-level discovery + trapper values.
#
# Sends one discovery payload (cputemp.discovery) plus per-sensor and an aggregate
# value, all in a single zabbix_sender batch. Server-side objects are created by
# playbooks/cpu-temp-monitor-zabbix-setup.yml; see docs/cpu-temp-monitoring.md.
#
# Same structure and lessons as scripts/smart-monitor.sh, which this was copied
# from — see that file for the fuller "why" of several choices repeated here
# (no `set -e`, hostname resolution order, reading zabbix_sender's own counters
# rather than trusting its exit code).

set -uo pipefail

ZABBIX_SERVER="${ZABBIX_SERVER:-10.0.5.9}"
ZABBIX_PORT="${ZABBIX_PORT:-10051}"

# Tried in order, purely to learn the Hostname= this machine is known by in
# Zabbix: a value sent under the wrong name is accepted by the server and then
# silently discarded. All four hosts run agent2, but this stays a LIST rather
# than a single path for the same reason smart-monitor.sh does -- a hardcoded
# agent1 path is what killed the fleet-update notifier during that migration.
ZABBIX_CONFS="${ZABBIX_CONFS:-/etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf}"

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

# Sensor ids are stable by construction here (chip name + feature name from
# lm-sensors' own driver), unlike SMART's USB drive letters -- there is no
# rotating-enumeration problem to work around, so no serial-style fallback is
# needed. Still sanitized because a feature label can contain spaces/parens
# ("Package id 0", "Core 0 (high)") and Zabbix item-key parameters treat
# , [ ] and whitespace specially.
sanitize_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | sed 's/_\{1,\}$//'; }

ZABBIX_HOST=$(resolve_hostname)
: > "$REPORT"

if ! command -v sensors >/dev/null 2>&1; then
	log "sensors (lm-sensors) not installed -- nothing to report"
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	log "jq not installed -- cannot parse 'sensors -j' output"
	exit 1
fi

SENSORS_JSON=$(sensors -j 2>/dev/null)
if [ -z "$SENSORS_JSON" ] || ! printf '%s' "$SENSORS_JSON" | jq -e . >/dev/null 2>&1; then
	log "ERROR: 'sensors -j' produced no usable JSON -- has sensors-detect been run?"
	exit 1
fi

# Walk every CPU chip -> feature -> *_input reading. Chip drivers differ across
# the fleet (coretemp on Intel, k10temp on AMD Zen, etc. -- the "chipsets may
# differ across the four" problem this monitor exists to handle), so nothing
# here assumes a specific driver beyond this known-CPU-driver allowlist. Only
# keys ending in *_input are actual readings; sibling _max/_crit/_hyst keys on
# the same feature are thresholds, not values to report.
#
# The allowlist matters: `sensors -j` also reports NVMe composite temperature
# (registered automatically by the kernel's nvme hwmon driver, with no
# sensors-detect needed) on the same hosts SMART already tracks drive
# temperature for. Without filtering, an NVMe reading would be discovered here
# and labeled "CPU <chip> (Composite): temperature" -- an actively wrong label,
# not just a redundant one, since it is a drive's temperature, not the CPU's.
#
# Output: one "chip<TAB>feature<TAB>value" line per reading.
CPU_CHIP_PATTERN='^(coretemp|k10temp|k8temp|zenpower|via-cputemp)-'

mapfile -t ALL_CHIPS < <(printf '%s' "$SENSORS_JSON" | jq -r 'keys[]' 2>/dev/null)
mapfile -t READINGS < <(
	printf '%s' "$SENSORS_JSON" | jq -r --arg pat "$CPU_CHIP_PATTERN" '
		to_entries[]
		| select(.key | test($pat))
		as $chip
		| $chip.value
		| to_entries[]
		| select(.value | type == "object")
		| . as $feature
		| $feature.value
		| to_entries[]
		| select(.key | endswith("_input"))
		| [$chip.key, $feature.key, .value] | @tsv
	' 2>/dev/null
)

if [ "${#READINGS[@]}" -eq 0 ]; then
	log "WARNING: no chip matched the known CPU driver list ($CPU_CHIP_PATTERN)."
	log "         Chips 'sensors -j' actually reported: ${ALL_CHIPS[*]:-(none)}"
	log "         If one of these is this host's CPU sensor under a driver not"
	log "         yet in the allowlist, add it to CPU_CHIP_PATTERN above."
fi

SENSOR_COUNT=0
MAX_TEMP=""
: > "$WORK_DIR/lld"
: > "$WORK_DIR/seen_ids"

for line in "${READINGS[@]}"; do
	[ -n "$line" ] || continue
	IFS=$'\t' read -r chip feature raw_temp <<< "$line"
	[ -n "$chip" ] && [ -n "$feature" ] && [ -n "$raw_temp" ] || continue

	# Round to the nearest integer -- matches the SMART monitor's precedent of
	# integer-only temperature items, and avoids surprising a Zabbix item whose
	# value type is numeric (unsigned).
	temp=$(awk -v t="$raw_temp" 'BEGIN { printf "%d", (t < 0 ? t - 0.5 : t + 0.5) }' 2>/dev/null)
	[[ "$temp" =~ ^-?[0-9]+$ ]] || continue
	# Guard against an obviously bogus reading (a disconnected/absent sensor
	# sometimes reports a large negative or implausible value).
	if [ "$temp" -lt -40 ] || [ "$temp" -gt 150 ]; then
		log "WARNING: ignoring implausible reading $chip/$feature = ${raw_temp}"
		continue
	fi

	id=$(sanitize_id "${chip}_${feature}")
	if [ -z "$id" ]; then
		log "WARNING: could not derive an id for $chip/$feature; skipping"
		continue
	fi
	if grep -qxF "$id" "$WORK_DIR/seen_ids" 2>/dev/null; then
		log "WARNING: duplicate sensor id '$id' ($chip/$feature); skipping"
		continue
	fi
	printf '%s\n' "$id" >> "$WORK_DIR/seen_ids"

	queue "cputemp.sensor[$id,value]" "$temp"
	printf '{"{#ID}":"%s","{#CHIP}":"%s","{#SENSOR}":"%s"}\n' \
		"$(json_escape "$id")" "$(json_escape "$chip")" "$(json_escape "$feature")" >> "$WORK_DIR/lld"
	printf '%s\t%s\t%s\n' "$chip" "$feature" "$temp" >> "$REPORT"

	if [ -z "$MAX_TEMP" ] || [ "$temp" -gt "$MAX_TEMP" ]; then
		MAX_TEMP="$temp"
	fi
	SENSOR_COUNT=$((SENSOR_COUNT + 1))
done

if [ "$SENSOR_COUNT" -eq 0 ]; then
	log "WARNING: no temperature sensors detected -- has sensors-detect been run?"
	exit 1
fi

# One JSON object per line above, joined here -- see smart-monitor.sh for why
# building the commas inside the loop instead would risk malformed JSON.
queue "cputemp.discovery" "[$(paste -sd, "$WORK_DIR/lld")]"
queue "cputemp.max" "$MAX_TEMP"

column -t "$REPORT" 2>/dev/null || cat "$REPORT"
echo "host=$ZABBIX_HOST sensors=$SENSOR_COUNT max=$MAX_TEMP"

if ! command -v zabbix_sender >/dev/null 2>&1; then
	log "zabbix_sender not installed -- skipping the Zabbix push"
	exit 1
fi

# The server reports success for the CONNECTION even when it discards every
# value for want of a matching item, so the counters have to be read back
# rather than trusting the exit status.
sender_out=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$ZABBIX_HOST" -i "$BATCH" 2>&1)
log "zabbix_sender: $sender_out"

case "$sender_out" in
	*"failed: 0"*) ;;
	*)
		log "WARNING: Zabbix discarded values sent as host '$ZABBIX_HOST'."
		log "         Run playbooks/cpu-temp-monitor-zabbix-setup.yml, or check that"
		log "         Hostname= in the agent config matches the Zabbix host name."
		;;
esac

# Exit status reflects the push, not temperature: a hot CPU is a normal,
# expected outcome to REPORT. Marking the systemd unit failed for it would bury
# a genuinely broken monitor among routine temperature alerts.
exit 0
