# Claude Code access — the `claude` identity

Runbook for `playbooks/users/claude-user.yml`, which provisions the account Claude Code
uses to operate this repo. A second, purpose-scoped playbook,
`playbooks/users/claude-user-zabbix.yml`, extends the same identity to
zabbix.home.lan — see [On zabbix.home.lan](#on-zabbixhomelan-exception-to-cockpit-only)
below for why that host is an explicit, reasoned exception rather than a reversal of
the policy. [On LiteLLM](#on-litellm-read-only-api-key-writes-go-through-ansible) covers
a third, differently-shaped case: no OS account at all, just a read-only API key.

## Design

| Decision | Reason |
|---|---|
| **cockpit only, plus one reasoned exception** | cockpit is the Ansible control node, so the whole fleet is reachable from there through reviewed playbooks — a second account elsewhere is normally redundant. zabbix.home.lan is the one exception (2026-09-21): real-time Zabbix server diagnostics (tailing `zabbix_server.log`, running `zabbix_server -R <subcommand>` on demand) don't fit the "capture one command's output through a reviewed playbook" shape cockpit-mediated access gives. No `claude` account exists on the other 11 hosts. |
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
ssh claude@cockpit 'id; cd /opt/ansible && sudo -n -H -u ansible /usr/bin/ansible --version | head -1'
```

`id` must show **no** `sudo` or `wheel` group, and the second command must print a
version. If `id` shows `sudo`, the sudoers rule is not the only escalation path and
something else granted it.

### 5. Reduce permission prompts

Add `Bash(ssh claude@*)` to `.claude/settings.json` in this repo so routine calls do not
prompt. Note the **space** before `*`, not a colon — that is the prefix-wildcard form
Claude Code generates and honors.

## Operating

Claude works through this pattern, never as root directly:

```bash
ssh claude@cockpit 'cd /opt/ansible && sudo -n -H -u ansible /usr/bin/ansible-playbook playbooks/<play>.yml --check --diff'
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

## On zabbix.home.lan (exception to cockpit-only)

`playbooks/users/claude-user-zabbix.yml` grants a narrower, purpose-built version of the
same identity directly on zabbix.home.lan, reusing the same keypair
(`keys/claude_ed25519.pub`) so `~/.ssh/config`'s `IdentityFile ~/.ssh/id_claude` covers
both hosts unchanged. It differs from `claude-user.yml` in what it actually grants:

| | cockpit (`claude-user.yml`) | zabbix.home.lan (`claude-user-zabbix.yml`) |
|---|---|---|
| Escalates to | `ansible` user, running `ansible`/`ansible-playbook`/`ansible-inventory` | **Nothing — no sudo at all** |
| Extra group | `ansible` (read `/opt/ansible`) | `zabbix` (read `/var/log/zabbix/zabbix_server.log`, mode `0640 zabbix:zabbix` — no sudo needed for this) |
| Grants | Effectively full fleet control via reviewed playbooks | Read-only: `zabbix_server.log` via group membership only |

**2026-09-23:** this used to also grant `claude` root escalation for two fixed, read-only
`zabbix_server -R config_cache_reload`/`-R ha_status` commands (`zabbix_server.conf` is
`0600 root:root`, so even a read-only `-R` call needs root to open it). Removed per policy:
`claude` never gets a root or `lfoss` escalation path anywhere, even a narrowly-scoped one — the
only escalation path anywhere for `claude` is `cockpit` → `ansible`. Re-running
`claude-user-zabbix.yml` actively strips this grant from any host it was previously applied to.

Bootstrap: same shape as cockpit's steps 3–5 above, run from cockpit as the `ansible`
user (which already manages zabbix.home.lan, like every other inventory host):

```bash
sudo -iu ansible
cd /opt/ansible
ansible-playbook playbooks/users/claude-user-zabbix.yml --check --diff
ansible-playbook playbooks/users/claude-user-zabbix.yml
```

Add a second block to `~/.ssh/config` on the workstation:

```
Host zabbix
    HostName 10.0.5.9
    User claude
    IdentityFile ~/.ssh/id_claude
    IdentitiesOnly yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Operating pattern — direct SSH, read-only, no sudo of any kind:

```bash
ssh zabbix 'tail -n 100 /var/log/zabbix/zabbix_server.log'
```

Editing `zabbix_server.conf` or reloading its config cache is `ansible`'s job now, not
`claude`'s — see `playbooks/manage-zabbix-server-conf.yml`, run from cockpit as `ansible`
the same way every other fleet change is made:

```bash
sudo -iu ansible
cd /opt/ansible
ansible-playbook playbooks/manage-zabbix-server-conf.yml --check --diff \
  -e '{"zabbix_server_conf_settings": [{"key": "SomeKey", "value": "SomeValue"}]}'
```

## On LiteLLM (read-only API key; writes go through Ansible)

Not an OS account at all — LiteLLM (litellm.home.lan / 10.2.6.1:4000, `litellm`
namespace) is an HTTP API, not a host Claude needs to log into, so the
zabbix.home.lan shape (SSH + group membership) doesn't apply. Same underlying
policy though: Claude gets read-only, reviewed writes go through Ansible.

| | cockpit (`claude-user.yml`) | LiteLLM |
|---|---|---|
| Access mechanism | SSH key, escalates to `ansible` | Bearer token, direct HTTPS call to the LiteLLM API — no SSH involved |
| Role | N/A (shell account) | LiteLLM `proxy_admin_viewer` — "view all keys, view all spend"; cannot call `/model/new`, `/model/update`, or `/model/delete` |
| Credential storage | `keys/claude_ed25519.pub` (git) + private half on the workstation | `LITELLM_API_TOKEN` / `LITELLM_API_URL` exported in `~/.bashrc` on the workstation — the same place `VAULT_PVE_TOKEN`, `VAULT_OPNSENSE_KEY`/`_SECRET`, and `ZABBIX_API_TOKEN`/`ZABBIX_API_URL` already live. Not committed to git. |
| Writes | Reviewed playbooks via `ansible` | `playbooks/manage-litellm-models.yml`, using a *separate* `ansible-litellm-writer` key (`proxy_admin` role) stored ansible-vault-encrypted in `group_vars/litellm.yml` — never the cluster's `PROXY_MASTER_KEY` secret, and never Claude's own read-only key |

Why two LiteLLM keys instead of one: same reasoning `group_vars/network_appliances.yml`
already gives for OPNsense's dedicated `ansible-writer` API user — one credential
serving two callers means neither can be revoked or re-scoped without breaking the
other, and that repo's own history already has an outage caused by exactly that
shortcut. Claude's key can't write regardless, so even if the two were merged
Claude would still route changes through the playbook — but keeping them separate
means the read-only key can be handed out more freely without it also being a
proxy_admin credential.

Both keys are minted directly on the live LiteLLM proxy (UI or API) and placed by
hand — not by Claude, since Claude has no path to `/etc/ansible-vault-password`
(its cockpit sudo grant covers only `ansible`/`ansible-playbook`/`ansible-inventory`,
not `ansible-vault`) and the read-only key is simplest to just set directly.

Operating pattern:

```bash
# Read — direct, no ansible involved
curl -s -H "Authorization: Bearer $LITELLM_API_TOKEN" "$LITELLM_API_URL/model/info"

# Write — reviewed playbook via cockpit, like every other fleet change
sudo -iu ansible
cd /opt/ansible
ansible-playbook playbooks/manage-litellm-models.yml --check --diff \
  -e '{"litellm_model_deletes": [{"model_id": "<id-from-model/info>"}]}'
```

Model inventory and known issues (retired NIM entries, OpenRouter quota, etc.) are
tracked in the vault at `Kubernetes/Services/litellm-models.md`, not here.

Rotating `ansible-litellm-writer` itself is `playbooks/rotate-litellm-writer-key.yml`
— it regenerates the key on the live proxy and re-encrypts it into
`group_vars/litellm.yml` in one run, with `no_log: true` on every task that ever
holds the plaintext so it never appears in Ansible's own console output. Run it the
same way, from cockpit as `ansible`.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `claude_hosts` | `cockpit.home.lan` | Where the account is created. Widen only with reason. |
| `claude_key_from` | `10.10.5.198` | Source-IP restriction on the key. Set to `""` to allow any source — needed if the workstation's DHCP lease moves. |
| `claude_extra_groups` | `[ansible]` | Read access to `/opt/ansible`. Grants no sudo. |
| `claude_sudo_commands` | `ansible`, `ansible-playbook`, `ansible-inventory` | Commands permitted as the `ansible` user. Paths are resolved on the target. |

## Related

- `playbooks/users/ansible-user.yml` — the automation identity `claude-user.yml` escalates to
- `playbooks/users/lfoss-user.yml` — the admin identity `claude-user.yml` is modeled on
- `playbooks/users/claude-user-zabbix.yml` — the zabbix.home.lan exception, see above
- `playbooks/manage-litellm-models.yml` / `group_vars/litellm.yml` — the LiteLLM write path, see above
- `playbooks/rotate-litellm-writer-key.yml` — rotates the ansible-litellm-writer key itself, see above
- `docs/ansible-user.md` — original bootstrap notes
