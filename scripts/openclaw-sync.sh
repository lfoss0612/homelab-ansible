#!/usr/bin/env bash
set -euo pipefail

ANSIBLE_DIR="/opt/ansible"
GATEWAY="10.0.5.7"
LOG="/var/log/openclaw-sync.log"

log() {
  echo "[$(date -Iseconds)] $*" | tee -a "$LOG"
}

log "Polling gateway for version..."

# Get gateway's running version
GATEWAY_VERSION=$(curl -fsS "http://${GATEWAY}/openclaw-version" \
  | jq -r .version 2>/dev/null) || {
  log "ERROR: Could not reach gateway"
  exit 1
}

# Get inventory's expected version
INVENTORY_VERSION=$(grep -E '^openclaw_version:' "$ANSIBLE_DIR/group_vars/openclaw.yml" \
  | head -1 \
  | sed -E 's/openclaw_version:[[:space:]]*"?([^"]+)"?.*/\1/')

log "Gateway: $GATEWAY_VERSION, Inventory: $INVENTORY_VERSION"

if [ "$GATEWAY_VERSION" = "$INVENTORY_VERSION" ]; then
  log "Versions match. Nothing to do."
  exit 0
fi

log "Version mismatch detected. Updating inventory and rolling out."

# Update group_vars
sudo sed -i "s/^openclaw_version:.*/openclaw_version: \"${GATEWAY_VERSION}\"/" \
  "$ANSIBLE_DIR/group_vars/openclaw.yml"

# Run the update playbook
cd "$ANSIBLE_DIR"
sudo -u ansible ansible-playbook playbooks/update-openclaw.yml \
  --vault-password-file /etc/ansible-vault-password \
  2>&1 | tee -a "$LOG"

log "Update complete."
