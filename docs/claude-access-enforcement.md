# Claude Access Enforcement Model

## Goal

Ensure Claude Code can ONLY use the `claude` account to access fleet hosts. No root, no ansible, no openclaw, no lfoss—only `claude` for SSH access, escalating to `ansible` only when needed to run playbooks.

## Current Enforcement

### 1. SSH Key Isolation ✓
- Claude's SSH key (`claude_ed25519.pub`) is installed **only** on the `claude` user account
- No other user accounts have this key in their `authorized_keys`
- Key is password-protected on the control machine

### 2. Sudoers Restrictions ✓
Claude's sudoers rules are tightly scoped per host:

**cockpit.home.lan:**
```
claude ALL=(ansible) NOPASSWD: /usr/bin/ansible, /usr/bin/ansible-playbook, /usr/bin/ansible-inventory
Defaults:claude !requiretty
```
- Claude escalates **only** to the `ansible` user
- **Only** specific ansible binaries can be run
- No other escalation paths

**pbs.home.lan, zabbix.home.lan:**
- No sudo/escalation of any kind on either host — `claude` cannot become `root`, `ansible`, or
  anyone else here
- Read access only, via group membership (zabbix, adm, systemd-journal)
- zabbix.home.lan previously (until 2026-09-23) also granted root escalation for two fixed
  `zabbix_server -R` diagnostic commands; removed per this document's own Goal above (no root
  path anywhere, not even a narrowly-scoped one). Editing `zabbix_server.conf` and reloading its
  config cache is now `ansible`'s job — see `playbooks/manage-zabbix-server-conf.yml`.

### 3. SSH Key Restrictions (Added) ✓
SSH supports runtime restrictions in `authorized_keys`:

```
no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-user-rc ssh-ed25519 AAAAC3...
```

These prevent:
- **no-port-forwarding**: Port tunneling attacks
- **no-X11-forwarding**: X11 display forwarding
- **no-agent-forwarding**: SSH agent forwarding (prevents key escalation)
- **no-user-rc**: Disables `~/.ssh/rc` execution (prevents shell initialization exploits)

On cockpit, `no-pty` is **NOT** added since Claude needs an interactive shell for ansible commands.

### 4. Account Isolation
- `claude` is **system user** (no login shell inheritance from other accounts)
- Home directory mode: `0700` (claude:claude) with traverse access for `ansible` group
- No group membership beyond `systemd-journal`, `adm` (read-only logs)
- No membership in `sudo`, `wheel`, or other privileged groups

## How Ansible Changes Are Made

```
claude SSH → ansible escalation via sudoers → ansible-playbook
   ↓                    ↓                            ↓
only via             only ansible user        changes via
claude key         (no other escalation)      playbooks
```

Both `claude` and `openclaw` agents run ansible through the same mechanism:
- `openclaw` node process runs ansible commands in automated tasks
- `claude` escalates to `ansible` user to run playbooks interactively
- **Ansible is the only write path** to the fleet

## Audit Checklist

### Automated (run before deployment):
```bash
# Verify no claude key on other accounts:
ansible all -m shell -a 'grep -l AAAAC3NzaC1lZDI1NTE5 /home/*/authorized_keys 2>/dev/null'

# Verify sudoers restricts claude properly:
ansible all -m shell -a 'grep -A2 "^claude" /etc/sudoers.d/* 2>/dev/null'

# Verify no root escalation for claude (except host-specific):
ansible all -m shell -a 'grep "claude.*ALL=" /etc/sudoers.d/* | grep -v "ansible"'
```

### Manual (for sensitive hosts):
```bash
ssh cockpit -u claude 'sudo -u root whoami'  # Should fail
ssh cockpit -u claude 'sudo -u ansible whoami'  # Should return 'ansible'
```

## Future Enhancements

1. **Automated access audit**: Add a playbook that verifies all constraints monthly
2. ~~**SSH session logging**: Enable SSH session recording for compliance~~ **Done 2026-09-23**,
   server-side rather than client-side (a client-side wrapper and a client-side `LocalCommand`
   were both tried and abandoned first — see `homelab-vault`
   `Incidents/2026-09-23-ssh-wrapper-broke-desktop-access.md`). `playbooks/deploy-claude-ssh-restrictions.yml`
   sets `LogLevel VERBOSE` on cockpit's sshd, which logs every login attempt server-side and can't
   be bypassed by client behavior. Not yet extended to `zabbix.home.lan`.
3. **Baseline SSH restrictions on all accounts**: Apply `no-port-forwarding,no-X11-forwarding` to all SSH keys fleet-wide.
   **Still deliberately scoped to `claude` only** — see the Goal above; do not widen this to other
   accounts without an explicit decision to do so.
4. **Host-specific SSH restrictions**: Tighten claude on backup/diagnostic hosts with additional options

