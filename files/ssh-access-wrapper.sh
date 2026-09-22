#!/bin/bash
# SSH Access Wrapper and Logger
# Logs all SSH connections for audit trail
#
# Install on control nodes (cockpit, desktop VM) to track access
# Replaces /usr/bin/ssh or wraps it via PATH modification
#
# Logs to:
# - /var/log/ssh-access.log (human-readable)
# - Zabbix trapper (optional)

set -e

SSH_BIN="/usr/bin/ssh.real"  # Original SSH binary (renamed)
LOG_FILE="/var/log/ssh-access.log"
AUDIT_DIR="/var/log/ssh-audit"
MAX_LOG_SIZE=$((100 * 1024 * 1024))  # 100MB log rotation

# Ensure audit directory exists
mkdir -p "$AUDIT_DIR"

# Function to log SSH connection
log_ssh_access() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local user=$(whoami)
  local host=""
  local port="22"
  local command=""

  # Parse SSH arguments to extract target and command
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p)
        shift
        port="$1"
        ;;
      -l)
        shift
        # Skip, we already have user
        ;;
      -*)
        # Skip other flags and their arguments
        if [[ "$1" =~ ^-[a-zA-Z]$ ]]; then
          shift
          [[ -n "$1" ]] && shift  # Skip argument if it exists
        else
          shift
        fi
        ;;
      *)
        if [[ -z "$host" ]]; then
          host="$1"
        else
          command="$1 ${@:2}"
          break
        fi
        shift
        ;;
    esac
  done

  # Log to file
  {
    echo "[$timestamp] user=$user host=$host port=$port command=$command"
  } >> "$LOG_FILE"

  # Also save as JSON for parsing
  local json_log="$AUDIT_DIR/$(date +%Y%m%d_%H%M%S)_$$_${host}.json"
  {
    echo "{"
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"unix_timestamp\": $(date +%s),"
    echo "  \"local_user\": \"$user\","
    echo "  \"target_host\": \"$host\","
    echo "  \"target_port\": $port,"
    echo "  \"command\": \"$command\","
    echo "  \"pid\": $$,"
    echo "  \"exit_code\": null"
    echo "}"
  } > "$json_log"

  # Rotate log if too large
  if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt $MAX_LOG_SIZE ]]; then
    gzip "$LOG_FILE" 2>/dev/null || true
    touch "$LOG_FILE"
  fi
}

# Function to send to Zabbix (optional)
send_to_zabbix() {
  local host="$1"
  local status="$2"

  if command -v zabbix_sender &>/dev/null; then
    zabbix_sender -z zabbix.home.lan -p 10051 \
      -s "$(hostname)" \
      -k "homelab.ssh.access.${host}" \
      -v "$status" 2>/dev/null || true
  fi
}

# Log this access
log_ssh_access "$@"

# Call original SSH binary
if [[ -f "$SSH_BIN" ]]; then
  exec "$SSH_BIN" "$@"
else
  # Fallback if original binary hasn't been renamed
  # This would be first installation
  exec ssh.real "$@" || exec /usr/bin/ssh "$@"
fi
