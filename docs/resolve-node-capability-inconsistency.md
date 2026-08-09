# Resolve Node Capability Approval Inconsistency

**Issue:** `pdm.home.lan` has `system.execApprovals.get` and `system.execApprovals.set` capabilities approved, but `omv.home.lan`, `pve.home.lan`, and `zabbix.home.lan` do not.

**Why this matters:** These capabilities are needed for nodes to handle re-approval requests for capability changes. All nodes should have a consistent baseline of approved capabilities.

## Resolution Steps

### Option 1: Using the ansible playbook (preferred)

```bash
cd /home/lfoss/projects/homelab-ansible
ansible-playbook playbooks/fix-node-capability-inconsistency.yml -e confirm=true
```

The playbook will:
1. Query the current node status from the gateway
2. Display what capabilities each node is missing
3. Approve `system.execApprovals.get` and `system.execApprovals.set` on the three nodes
4. Verify the changes

### Option 2: Manual approval on the gateway

1. SSH to the gateway (cockpit.home.lan or the gateway's direct IP)

2. Query node IDs:
```bash
openclaw nodes status --json | jq '.nodes[] | {displayName, id}' | grep -E "omv|pve|zabbix"
```

3. For each node ID, approve the two capabilities:
```bash
# Replace <NODE_ID> with the actual ID from the query above
openclaw nodes approve-capability <NODE_ID> system.execApprovals.get
openclaw nodes approve-capability <NODE_ID> system.execApprovals.set
```

4. Verify the changes:
```bash
openclaw nodes status --json | jq '.nodes[] | select(.displayName | IN("omv.home.lan", "pve.home.lan", "zabbix.home.lan")) | {displayName, caps}'
```

All three nodes should now show `system.execApprovals.get` and `system.execApprovals.set` in their capabilities, matching `pdm.home.lan`.

## Result

After approval, all four nodes (`pdm`, `omv`, `pve`, `zabbix`) will have the same baseline of approved capabilities, eliminating the fleet inconsistency.
