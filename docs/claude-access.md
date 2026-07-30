# Claude Code access — the `claude` identity

Runbook for `playbooks/users/claude-user.yml`, which provisions the account Claude Code
uses to operate this repo.

## Design

| Decision | Reason |
|---|---|
| **cockpit only** | cockpit is the Ansible control node, so the whole fleet is reachable from there through reviewed playbooks. No `claude` account exists on the other 12 hosts. |
| **Key auth, password locked** | Claude Code's shell calls have no TTY, so a password prompt cannot be answered. Every workaround (`sshpass`, a password in a file) writes the credential into the session transcript. Matches the keys-only convention from `ansible-user.yml`. |
| **Not in `sudo`/`wheel`** | The only escalation is a scoped rule permitting Ansible as the `ansible` user. No direct root on cockpit. |
| **`from=` on the key** | Restricts the key to the workstation it is used from. |
| **Defined in git** | Access is reproducible and reviewable, and survives a cockpit rebuild. |

### What the grant actually allows

Running `ansible-playbook` as the `ansible` user is **effectively root on all 13
inventory hosts**, because a playbook can do anything. This is not a capability
reduction. What it buys:

- **Attribution** — `journalctl _UID=$(id -u claude)`, sudo logs, and `last` separate
  Claude's actions from your own `lfoss` work and from unattended timer runs.
- **Independent revocation** — removing `claude` does not disturb automation.
- **No direct root on cockpit** outside of Ansible.

Real capability limits come from withholding the vault password and running
`--check --diff` first.

## Bootstrap

### 1. Generate the keypair (workstation, as `lfoss`)

No passphrase — Claude Code cannot type one. The private key is protected by file
permissions, the same posture as `/home/ansible/.ssh/id_ed25519`.

```bash
ssh-keygen -t ed25519 -a 100 -C 'claude-code@workstation' -f ~/.ssh/id_claude -N ''
install -m 644 ~/.ssh/id_claude.pub /mnt/projects/homelab-ansible/keys/claude_ed25519.pub
```

Only the **public** half is committed, matching `keys/ansible.pub`.

### 2. Get the playbook onto cockpit

Find out what `/opt/ansible` is first:

```bash
ls -d /opt/ansible/.git && git -C /opt/ansible remote -v
```

- **Git checkout** → commit and push from the workstation, then
  `git -C /opt/ansible pull --ff-only`
- **Not a checkout, `/mnt/projects` mounted** → copy `playbooks/users/claude-user.yml`
  and `keys/claude_ed25519.pub` into the matching paths under `/opt/ansible`
- **Neither** → paste the file in via the Cockpit web terminal

### 3. Dry run, then apply

Run on cockpit as the `ansible` user, whose key already lives there — no
chicken-and-egg with an account that does not exist yet.

```bash
sudo -iu ansible
cd /opt/ansible
ansible-playbook playbooks/users/claude-user.yml --limit cockpit.home.lan --check --diff
ansible-playbook playbooks/users/claude-user.yml --limit cockpit.home.lan
```

Requires the `ansible.posix` collection, already a dependency of `lfoss-user.yml`:

```bash
ansible-galaxy collection list ansible.posix
```

The playbook self-tests at the end, printing `claude -> ansible OK: ansible [core …]`.

### 4. Wire up the client side (workstation)

Add to `~/.ssh/config`:

```
Host cockpit
    HostName 10.0.5.10
    User claude
    IdentityFile ~/.ssh/id_claude
    IdentitiesOnly yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

`ControlPersist` matters: a discovery sweep is ~20 commands over one connection instead
of 20 handshakes. `IdentitiesOnly yes` stops SSH from offering other keys in the agent,
so the `from=`-pinned key is the only one tried.

Trust the host key explicitly rather than accepting it blind on first connect. On cockpit:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare against `ssh-keyscan -t ed25519 10.0.5.10 | ssh-keygen -lf -` from the
workstation before appending it to `~/.ssh/known_hosts`.

Verify end to end:

```bash
ssh cockpit 'id; cd /opt/ansible && sudo -n -H -u ansible /usr/bin/ansible --version | head -1'
```

`id` must show **no** `sudo` or `wheel` group, and the second command must print a
version. If `id` shows `sudo`, the sudoers rule is not the only escalation path and
something else granted it.

### 5. Reduce permission prompts

Add `Bash(ssh cockpit *)` to `.claude/settings.json` in this repo so routine calls do not
prompt. Note the **space** before `*`, not a colon — that is the prefix-wildcard form
Claude Code generates and honors.

## Operating

Claude works through this pattern, never as root directly:

```bash
ssh cockpit 'cd /opt/ansible && sudo -n -H -u ansible /usr/bin/ansible-playbook playbooks/<play>.yml --check --diff'
```

### Two details that are easy to get wrong

**Always `cd /opt/ansible` first.** The sudoers rule permits the root-owned binaries in
`/usr/bin`, which find `ansible.cfg` only by cwd auto-discovery. An `ssh` one-liner starts
in `claude`'s home directory, so without the `cd` Ansible silently falls back to the wrong
inventory and `collections_paths`. It does not error — it just does the wrong thing.
`sudo` preserves the working directory, so the `cd` carries through.

**Why the sudoers rule does not point at `/home/ansible/bin/`.** The `ansible` user has
wrapper scripts there that export `ANSIBLE_CONFIG` and exec the real binary, which would
make the `cd` unnecessary. They are deliberately excluded: they are mode `775` owned
`ansible:ansible`, and this playbook puts `claude` in the `ansible` group — so permitting
them would let `claude` rewrite the very thing `sudo` executes. Pointing the rule at
root-owned `/usr/bin` binaries keeps its resolved-path guarantee meaningful.

Note also that `Defaults secure_path` in Debian's sudoers means a bare `ansible-playbook`
under `sudo` always resolves to `/usr/bin`, regardless of anyone's `PATH`.

Audit what it did:

```bash
journalctl _UID=$(id -u claude) --since today
grep claude /var/log/auth.log
```

## Revoking

```bash
sudo rm -f /etc/sudoers.d/claude
sudo userdel -r claude
```

Automation is unaffected — the `ansible` identity is untouched. To re-grant, re-run the
playbook.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `claude_hosts` | `cockpit.home.lan` | Where the account is created. Widen only with reason. |
| `claude_key_from` | `10.10.5.198` | Source-IP restriction on the key. Set to `""` to allow any source — needed if the workstation's DHCP lease moves. |
| `claude_extra_groups` | `[ansible]` | Read access to `/opt/ansible`. Grants no sudo. |
| `claude_sudo_commands` | `ansible`, `ansible-playbook`, `ansible-inventory` | Commands permitted as the `ansible` user. Paths are resolved on the target. |

## Related

- `playbooks/users/ansible-user.yml` — the automation identity this one escalates to
- `playbooks/users/lfoss-user.yml` — the admin identity this playbook is modeled on
- `docs/ansible-user.md` — original bootstrap notes
