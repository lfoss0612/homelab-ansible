# Claude Code Access Control: Implementation Summary

Design and implementation plan for Claude Code access control across homelab infrastructure with a
7-layer security model.

**Status (2026-09-23, corrected):** the six items below describe playbooks and scripts written for
this model, not a deployed system. Nothing has actually been run against a live host yet. The
original version of this document claimed "All 6 issues complete and deployed" -- that was
inaccurate; see `homelab-vault/TODO.md` → "Ansible — Claude access control deployment" for the real
outstanding rollout steps, and `docs/claude-access.md` for what is actually running today (`claude`
on `cockpit` + the `zabbix.home.lan` exception only).

## Designed Issues (0 of 6 actually deployed)

### Issue #1: Git Hook Security Validation
**Status:** Script written, not confirmed installed anywhere

Hook scripts written for pre-commit and pre-push checks across three repositories:
- `homelab-ansible`
- `homelab-gitops`
- `homelab-vault`

**Features:**
- Blocks NOPASSWD: ALL and shell escalations
- Detects private keys and certificates
- Validates sudoers files for dangerous patterns
- Validates SSH authorized_keys for missing restrictions
- Skips .yml/.yaml files (legitimate parameter names)
- Uses grep -F for literal string matching (no regex false positives)

**Hook Location:** `~/.claude/git-hooks/pre-commit-security.sh`

### Issue #2: SSH Wrapper Deployment
**Status:** Written, not deployed to cockpit/desktop yet

SSH access logging wrapper written for control nodes (cockpit, desktop) to track `claude`/`openclaw`
SSH connections for audit trail. Every other account (`ansible`, `lfoss`, `root`, ...) passes
through untouched -- the wrapper replaces `/usr/bin/ssh` system-wide, so it filters by invoking
user internally (`LOGGED_USERS` allowlist in the script; an earlier draft was missing this check
and logged every account).

**Files Created:**
- `playbooks/deploy-ssh-access-logging.yml` - Deployment playbook
- `files/ssh-access-wrapper.sh` - Wrapper script with error handling
- `docs/ssh-wrapper-recovery.md` - Recovery guide for failed deployments

**Features:**
- Logs `claude`/`openclaw` SSH connections to `/var/log/ssh-access.log`
- JSON audit logs in `/var/log/ssh-audit/`
- Automatic log rotation (100MB)
- Silent error handling (doesn't break SSH if logs fail)
- Pre-deployment syntax validation
- Original SSH binary backup to `/usr/bin/ssh.real`

**Deploy:**
```bash
ansible-playbook playbooks/deploy-ssh-access-logging.yml --check --diff
ansible-playbook playbooks/deploy-ssh-access-logging.yml
```

### Issue #3: Zabbix Items Creation
**Status:** Playbook written, items not created in Zabbix yet

Playbook written to create Zabbix trapper items for receiving audit results.

**Files Created:**
- `playbooks/setup-claude-audit-zabbix-items.yml`

**Items Created:**
1. `homelab.claude.access.audit` - Overall status (text: PASSED/FAILED)
2. `homelab.claude.access.audit.violations` - Violation count (numeric)
3. `homelab.claude.access.audit.ssh_restrictions` - SSH key validation (1/0)
4. `homelab.claude.access.audit.sudoers` - Sudoers validation (1/0)

**Deploy:**
```bash
ansible-playbook playbooks/setup-claude-audit-zabbix-items.yml \
  -e zabbix_api_cred=<password>
```

### Issue #4: Audit Scheduling
**Status:** Playbook written, timer not installed yet

Playbook written for a systemd timer to run automated weekly audits. Depends on Issues #2 and #3
above (the audit has nothing to log to or receive results from until those are deployed).

**Files Created:**
- `playbooks/setup-claude-audit-timer.yml`

**Timer Configuration:**
- Schedule: Monday 2:00 AM UTC
- Runs: `audit-claude-access.yml` playbook
- Sends results to Zabbix automatically
- Logs via journalctl

**Deploy:**
```bash
ansible-playbook playbooks/setup-claude-audit-timer.yml
```

**Manual Trigger:**
```bash
systemctl start claude-access-audit.service

# View logs
journalctl -u claude-access-audit.service -f
```

### Issue #5: Git Hook Grep Warning
**Status:** Claimed fixed, not independently verifiable

`grep -F` (literal string matching) is intended to eliminate false `grep: unrecognized option`
warnings in the pre-commit hook. The hook source lives only at
`~/.claude/git-hooks/pre-commit-security.sh` on the local workstation, not in any repo, so this
can't be confirmed from a repo checkout -- verify the local script actually uses `grep -F` before
relying on this.

**Changes:**
- Replaced regex patterns with grep -F (literal string matching)
- Certificate patterns no longer interpreted as grep options
- Cleaner output without warnings

### Issue #6: Git Hooks Verification
**Status:** Not verified

No confirmed record of the commands below actually being run against real local checkouts of all
three repos. A fresh clone of `homelab-vault` has no `.git/hooks/pre-commit`/`pre-push` installed
(only git's default `.sample` files) -- run this checklist for real in each repo before trusting it.

**Verification:**
```bash
# Check all hooks installed
for repo in homelab-{ansible,gitops,vault}; do
  ls -la ~/projects/$repo/.git/hooks/pre-commit
done

# Test hook blocking
cd ~/projects/homelab-gitops
echo "sudoers: ALL=NOPASSWD: ALL" > test.yml
git add test.yml  # Should be blocked
```

## 7-Layer Security Model

### Layer 1: Desktop Hook (Claude Mobile Limitation)
- **File:** `~/.claude/hooks/access-guard.py`
- **Function:** Validates commands before execution
- **Blocks:** sudo/SSH to protected hosts
- **Note:** Mobile Claude app cannot invoke (file system access restriction)

### Layer 2: Git Pre-Commit Hook
- **Location:** `.git/hooks/pre-commit` (all 3 repos)
- **Function:** Blocks dangerous commits before staging
- **Blocks:** Credentials, NOPASSWD: ALL, private keys

### Layer 3: Git Pre-Push Hook
- **Function:** Final check before pushing to remote
- **Location:** `.git/hooks/pre-push`

### Layer 4: SSH Key Restrictions
- **Location:** `/home/claude/.ssh/authorized_keys`
- **Restrictions:**
  - `from="10.10.5.0/24"` - IP-based access
  - `no-port-forwarding` - No tunneling
  - `no-X11-forwarding` - No X11
  - `no-agent-forwarding` - No SSH agent
  - `no-user-rc` - No startup scripts

### Layer 5: Sudoers Whitelisting
- **File:** `/etc/sudoers.d/claude`
- **Model:** Whitelist only specific commands per host
- **Cockpit:** `ansible`, `ansible-playbook`, `ansible-inventory`
- **PBS:** No escalation allowed
- **Zabbix:** Specific diagnostic commands only

### Layer 6: SSH Access Logging
- **Wrapper:** `/usr/local/bin/ssh-wrapper`
- **Logs:** `/var/log/ssh-access.log` + JSON audit directory -- `claude`/`openclaw` only, every
  other account passes through untouched (`LOGGED_USERS` allowlist in the script)
- **Hosts:** cockpit, desktop

### Layer 7: Audit & Monitoring
- **Playbook:** `playbooks/audit-claude-access.yml`
- **Schedule:** Weekly (Monday 2 AM UTC)
- **Reports:** Zabbix + journalctl

## Essential Files Reference

| File | Purpose |
|------|---------|
| `collections/.../common/tasks/main.yml` | Creates claude user with SSH key |
| `playbooks/audit-claude-access.yml` | Validates access controls fleet-wide |
| `playbooks/setup-claude-audit-zabbix-items.yml` | Creates Zabbix trapper items |
| `playbooks/setup-claude-audit-timer.yml` | Schedules weekly audits |
| `playbooks/deploy-ssh-access-logging.yml` | Deploys SSH wrapper |
| `files/ssh-access-wrapper.sh` | SSH logging wrapper script |
| `docs/claude-access.md` | Full access runbook |
| `docs/ssh-wrapper-recovery.md` | Recovery guide |
| `~/.claude/hooks/access-guard.py` | Desktop command validator |
| `~/.claude/git-hooks/pre-commit-security.sh` | Git pre-commit security checks |

## Deployment Checklist

- [x] Claude user exists on cockpit + zabbix.home.lan exception (via common role / claude-user-zabbix.yml)
- [x] SSH key restrictions enforced for `claude` (no-* options)
- [x] Sudoers whitelisting configured for `claude` per host
- [ ] Git hooks actually installed and tested in all 3 repos' local checkouts
- [ ] SSH wrapper deployed on control nodes (script fixed 2026-09-23 to filter by user; still not run)
- [ ] Zabbix items created for monitoring
- [ ] Audit timer scheduled (Monday 2 AM UTC)
- [x] Recovery documentation written
- [ ] Any of the above actually tested end-to-end

## Testing & Verification

```bash
# Test git hooks
cd ~/projects/homelab-ansible
echo "password=\"secret\"" > test.py
git add test.py  # Should be blocked

# Verify SSH wrapper
ssh cockpit 'tail /var/log/ssh-access.log'

# Run manual audit
ansible-playbook playbooks/audit-claude-access.yml --check

# Verify timer status
ssh cockpit 'systemctl status claude-access-audit.timer'
```

## Integration Points

### Zabbix Monitoring
- 4 trapper items receive audit results weekly
- Violations trigger alerting
- Dashboard shows compliance status

### Journalctl Logging
- `claude`/`openclaw` SSH connections logged (once Issue #2 is deployed) -- every other account untouched
- Audit timer events logged (once Issue #4 is deployed)
- Systemd timer status queryable (once Issue #4 is deployed)

### Ansible Automation
- Common role provisions claude user fleet-wide
- Host-specific sudoers via playbooks
- Audit playbook runs weekly via timer

## Known Limitations

1. **Mobile Claude:** Desktop hook unavailable (file system access)
   - Mitigated by: Git hooks + server-side audit (6 other layers)

2. **SSH Wrapper Recovery:** Requires console access if SSH breaks
   - Mitigated by: Recovery guide + pre-deployment validation

3. **Timer Scope:** Runs on cockpit, audits all hosts
   - Acceptable: Cockpit is central control node

## Next Steps (Optional)

1. **Enhanced Alerting:** Configure Zabbix webhooks for violations
2. **Automated Recovery:** Add remediation playbook for common violations
3. **Dashboard:** Create Grafana dashboard for access audit metrics
4. **Compliance Reports:** Export audit results for compliance tracking

## Support References

- **Claude Access Runbook:** `docs/claude-access.md`
- **SSH Wrapper Recovery:** `docs/ssh-wrapper-recovery.md`
- **Ansible Configuration:** `docs/execution-model.md`
- **Main README:** `README.md`

---

**Design Date:** 2026-09-22 · **Corrected:** 2026-09-23  
**Status:** 7 layers designed, 0 confirmed deployed to a live host -- see Deployment Checklist above  
**Security Layers:** 7 designed, scoped to `claude`/`openclaw` only  
**Repos Targeted:** 3 (ansible, gitops, vault) -- hooks not yet confirmed installed in any  
**Hosts Monitored:** none yet (audit playbook untested against live infrastructure)
