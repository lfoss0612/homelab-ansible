# Resolve Node Command Approval Inconsistency

**Issue:** The OpenClaw fleet has an inconsistency in approved commands:
- **Have `system.execApprovals.get/set`:** cockpit, desktop, pdm, pve
- **Missing `system.execApprovals.get/set`:** omv, zabbix (and others)

**Scope of this fix:** Specifically resolving omv and zabbix to match pdm and pve.

**Why this matters:** These commands allow nodes to request new capability approvals without requiring manual gateway intervention. Nodes lacking these commands cannot re-declare their capabilities automatically.

## Resolution Steps

Commands in OpenClaw are approved when a node first pairs or when it re-declares its capabilities during an update. To approve `system.execApprovals.get/set` on omv and zabbix:

### Step 1: Trigger node re-declaration

Restart the OpenClaw nodes on omv and zabbix to force them to re-declare their capabilities:

```bash
# On omv.home.lan
systemctl restart openclaw-node

# On zabbix.home.lan  
systemctl restart openclaw-node
```

### Step 2: Wait for pending re-approval requests

The nodes will connect to the gateway and enter a "pending-reapproval" state. On the gateway, check for pending requests:

```bash
openclaw nodes pending
```

Look for omv and zabbix in the pending list. Their `approvalState` should show as `pending-reapproval`.

### Step 3: Approve the re-approval requests

Once the nodes appear in pending, approve their re-approval requests:

```bash
openclaw nodes approve <pendingRequestId>
```

Where `<pendingRequestId>` is the request ID shown in the pending list for each node.

### Step 4: Verify

After approval, verify the commands are now present:

```bash
openclaw nodes status --json | jq '.nodes[] | select(.displayName | IN("omv.home.lan", "zabbix.home.lan")) | {displayName, commands}'
```

Both nodes should now include `system.execApprovals.get` and `system.execApprovals.set` in their commands, matching pdm and pve.

## Note

This is a one-time approval that gets recorded by the gateway. Once approved, the nodes retain these command permissions across restarts.
