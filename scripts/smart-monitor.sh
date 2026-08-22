#!/bin/bash
# Monitor SMART status of all drives and report to Zabbix
# Sends metrics via zabbix_sender

set -euo pipefail

ZABBIX_SERVER="${ZABBIX_SERVER:-10.0.5.9}"
ZABBIX_PORT="${ZABBIX_PORT:-10051}"
HOSTNAME="${HOSTNAME:-$(hostname -f)}"
TEMP_FILE=$(mktemp)
OVERALL_STATUS=0

# Colors for output (when not piped to Zabbix)
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

cleanup() {
	rm -f "$TEMP_FILE"
}
trap cleanup EXIT

send_to_zabbix() {
	local key="$1"
	local value="$2"

	# Format: hostname key value clock
	{
		echo "- $key $value"
	} | zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -s "$HOSTNAME" -i - > /dev/null 2>&1 || {
		echo "Warning: Failed to send $key to Zabbix" >&2
		return 1
	}
}

check_drive() {
	local device="$1"
	local drive_status=0

	if ! smartctl -a "$device" > "$TEMP_FILE" 2>&1; then
		echo -e "${RED}ERROR${NC}: smartctl failed for $device"
		send_to_zabbix "smart.drive.${device##*/}.status" "2"  # 2 = error
		return 2
	fi

	local device_short="${device##*/}"

	# Check overall health status
	if grep -q "SMART overall-health self-assessment test result: PASSED" "$TEMP_FILE"; then
		echo -e "${GREEN}✓${NC} $device: PASSED"
		send_to_zabbix "smart.drive.${device_short}.status" "0"  # 0 = ok
	elif grep -q "SMART overall-health self-assessment test result: FAILED" "$TEMP_FILE"; then
		echo -e "${RED}✗${NC} $device: FAILED"
		send_to_zabbix "smart.drive.${device_short}.status" "1"  # 1 = failed
		drive_status=1
		OVERALL_STATUS=1
	fi

	# Extract temperature
	local temp=$(grep "Temperature_Celsius" "$TEMP_FILE" | grep -oP '\d+\s*$' | tail -1)
	if [[ -n "$temp" ]]; then
		send_to_zabbix "smart.drive.${device_short}.temperature" "$temp"
	fi

	# Check for critical attributes
	if grep -q "FAILED" "$TEMP_FILE"; then
		# Extract failed attributes
		local failed_attrs=$(grep "FAILED" "$TEMP_FILE")
		echo -e "${RED}Failed attributes detected:${NC}"
		echo "$failed_attrs"
		send_to_zabbix "smart.drive.${device_short}.failed_attrs" "1"
		drive_status=1
		OVERALL_STATUS=1
	else
		send_to_zabbix "smart.drive.${device_short}.failed_attrs" "0"
	fi

	return $drive_status
}

# Get list of drives
drives=$(smartctl --scan 2>/dev/null | grep -E "^/dev/" | awk '{print $1}' || echo "")

if [[ -z "$drives" ]]; then
	echo -e "${YELLOW}Warning: No drives detected by smartctl${NC}"
	send_to_zabbix "smart.status" "2"  # 2 = warning
	exit 0
fi

echo "Checking $(echo "$drives" | wc -l) drive(s)..."

# Check each drive
while IFS= read -r device; do
	check_drive "$device"
done <<< "$drives"

# Send overall status
send_to_zabbix "smart.status" "$OVERALL_STATUS"

if [[ $OVERALL_STATUS -eq 0 ]]; then
	echo -e "${GREEN}All drives healthy${NC}"
	exit 0
else
	echo -e "${RED}One or more drives have issues${NC}"
	exit 1
fi
