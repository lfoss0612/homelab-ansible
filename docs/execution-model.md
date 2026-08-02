# Execution model — read plane vs write plane

Standing decision, 2026-08-01. Fleet work is split by **verb**, not by host.

| Plane | Tool | Scope |
|---|---|---|
| **Read** | OpenClaw nodes (12 hosts) | Observe, tail logs, inspect running state, debug interactively. No host mutation. |
| **Write — hosts** | Ansible, from cockpit | Every change to a host goes through a playbook in this repo. |
| **Write — cluster** | Argo CD (`homelab-gitops`) | Everything in-cluster. Neither OpenClaw nor Ansible should touch k8s workloads. |

## Why

- **Git is the change record.** A change made through a playbook is reviewable, repeatable,
  and survives a host rebuild. A change made by hand on a node exists nowhere.
- **Per-node change execution fights Argo CD.** `k8s-master`, `k8s-worker`, and
  `k8s-worker-2` are OpenClaw nodes, but every app in `homelab-gitops` is `selfHeal: true` —
  a local "fix" there is reverted, and the agent ends up fighting the reconciler.
- **Upgrade cost scales with the number of independent installs.** Version skew, per-host
  npm prefixes, and the Memory Core sqlite migration bug are each multiplied by 12 when
  nodes are the thing making changes. When they only read, their version matters much less.
- **Blast radius.** One scoped, audited escalation path on cockpit beats twelve.

## The rule in practice

When something is found via an OpenClaw node, **do not fix it on the host.** Write or
extend the playbook here and run it. If the fix feels too small to justify a playbook,
that is exactly the change that will be invisible at rebuild time.

## Current state — enforced and verified

**Applied fleet-wide on 2026-08-01.** All 12 hosts now report `openclaw adm
systemd-journal`, `User openclaw is not allowed to run sudo`, and a readable journal line
from a unit the agent does not own. Verified by direct observation on every host, not by a
playbook recap — see [Verifying](#verifying) below.

The history of what was found and removed is kept below, because it explains why the role
manages sudoers at all and what will silently come back if that is ever dropped.

### What the audit found

An audit on 2026-08-01 (`ansible openclaw -m shell -a 'id openclaw; sudo -l -U openclaw'`)
found that **every node granted the `openclaw` user passwordless sudo, and none of it was
managed by this repo.** Those sudoers files predated the npm rewrite and were not in git.

| Hosts | Grant |
|---|---|
| `pve`, `pve-ai`, `omv`, `zabbix`, `pdm`, `cockpit`, `pbs`, `vscode`, `k8s-master`, `k8s-worker`, `k8s-worker-2` | `(ALL) NOPASSWD: /usr/bin/systemctl` |
| `openclaw` (gateway) | `(root) NOPASSWD: /bin/systemctl restart openclaw-gateway`, `status openclaw-gateway` |

Unrestricted `systemctl` as root is **a full root escalation**, not a service-restart
grant: `openclaw` owns its home directory, so `systemctl link ~/unit.service && systemctl
start unit` runs arbitrary code as root. Eleven of twelve nodes were therefore
root-capable. Only the gateway's grant was correctly scoped.

The `openclaw` user was otherwise clean — a system account, no supplementary groups
(except `_ssh` on `omv`), and `openclaw-node.service` already set `NoNewPrivileges=true`.

## How the grant is revoked

The `common` role now owns the `openclaw` user's sudo posture, driven by
`openclaw_sudo_commands` (default `[]` — no root capability at all):

- **`/etc/sudoers.d/openclaw` is removed** when the list is empty, or rewritten from it
  when non-empty. Entries must be exact commands *with arguments*, never a bare binary.
- **Inline `openclaw ALL=…` lines are stripped from `/etc/sudoers`**, which is where the
  gateway's grant lived (line 48) rather than in `sudoers.d`.
- Both tasks run `validate: visudo -cf %s`. This is load-bearing — a malformed sudoers
  file locks *every* user out of sudo, so validation happens on the temp file before it is
  moved into place.

### The read half — group membership, not sudo

Revoking sudo alone would have made the *read* plane worse, not just safer. An audit on
2026-08-01 found the `openclaw` user in **no supplementary groups** (except `_ssh` on
`omv`), which means:

- `journalctl -u openclaw-node` works on 10 of 12 hosts only because journald lets a uid
  read its own unit's entries. On the **gateway** and **k8s-worker** even that fails
  (`insufficient permissions`).
- No other service's journal is readable at all.
- `/var/log/syslog` is `syslog:adm 0640` on `zabbix`, `vscode`, `k8s-master`,
  `k8s-worker`, `k8s-worker-2` — unreadable.

So any debugging beyond the agent's own service was going *through* the sudo grant. The
`common` role therefore also puts the user in `openclaw_read_groups`, default
`systemd-journal` + `adm`: full journal for every unit, plus the `root:adm` / `syslog:adm`
files under `/var/log` including the Proxmox task logs. Both are read-only by
construction — neither can restart, write, or escalate. Groups missing on a host are
skipped, never created.

The accepted tradeoff: the agent can read `auth.log` and any secret that leaks into a log
line. That is inherent to "can read the logs" and is why the list is a variable.

Membership is resolved at process start, so a `common` handler restarts whichever
`openclaw-*` units already exist — otherwise the access silently would not take effect
until the next unrelated restart.

### Nothing in this repo depended on the sudo grant

Every `systemctl` call in `update-openclaw.yml`
and `validate-openclaw.yml` runs under Ansible's own `become: true` as the `ansible`
identity, not as `openclaw`. What did depend on it is the **agent's own runtime ability to
restart its service** — precisely the write-plane capability being withdrawn. Any OpenClaw
workflow that restarts a unit now fails, by design.

## Applying it

Use `--tags privileges`, and dry-run first. The tag matters twice over:

- An **untagged** run also fires `common`'s npm install task. When this was written the
  fleet was on `2026.5.26` against a pin of `2026.7.1-2`, so an untagged run would have
  upgraded every node as a side effect of a security fix.
- The tag is on the `include_role` in both the `node` and `gateway` roles as well as on
  `common`'s own tasks. With a dynamic include, `--tags` is matched against the include
  first, so an untagged include is filtered out and the inner tags never get a chance —
  which shows up as `ok=1, changed=0` per host and reads exactly like a clean pass.

```bash
ansible-playbook playbooks/deploy-openclaw.yml --tags privileges --check --diff
```

Expect `changed=3` per node (group grant, `sudoers.d` removal, handler restart) and
`skipped=1`. `changed=0` means the tag filter selected nothing — do not read it as
idempotence.

## Verifying

Recaps are not evidence. Confirm both halves directly — no root, but logs readable:

```bash
ansible openclaw -m shell -a '
  id -nG openclaw
  sudo -l -U openclaw 2>&1 | tail -2
  runuser -u openclaw -- journalctl -u ssh -n 1 --no-pager 2>&1 | tail -1'
```

Expect `openclaw adm systemd-journal`, `User openclaw is not allowed to run sudo`, and a
real log line from a unit the agent does **not** own. All 12 hosts satisfied this on
2026-08-01.

`pve-router` is not in `openclaw_nodes`, so its own `openclaw` user keeps whatever grant it
has. That host is independently managed and deliberately out of scope.

## What this does not cover

The OS boundary is enforced here; the **capability** boundary is not, and Ansible does not
manage it. Every node has `system.run` approved at the gateway, so the gateway can execute
arbitrary commands on all 12 — now as the unprivileged `openclaw` user rather than root,
which is the substance of what this change bought, but not literally read-only. Tightening
that means changing what the gateway approves, a separate mechanism from this repo.

Related, from `openclaw doctor --lint`: `gateway.auth.token` is stored **in plaintext** in
`openclaw.json` on the gateway, and doctor's own warning is that "agents or workspace tools
that can read config files may see these API keys/tokens". The `openclaw` identity is
exactly such a reader, and that token is the fleet-wide node credential.

## TODO — gateway security, scheduled after Phase 8

Deferred by decision on 2026-08-01: Phase 8 (the cockpit convergence timer) goes first,
these follow. All three surfaced from `openclaw doctor --lint` on the gateway, which only
started running once `validate-openclaw.yml` was fixed — nothing had been checking.

**None of them are Ansible fixes.** They are `openclaw config` / `openclaw secrets`
changes on the gateway, so keeping them in git means either a new role that templates
gateway config or a documented runbook. Applying them by hand leaves no record, which is
the exact failure this whole document exists to prevent.

1. **`gateway.auth.token` is stored in plaintext** in `openclaw.json` on the gateway.
   Doctor's warning: "agents or workspace tools that can read config files may see these
   API keys/tokens" — the `openclaw` identity is exactly such a reader, and this is the
   fleet-wide node credential. Fix with `openclaw secrets configure` / `secrets apply`,
   verify with `openclaw secrets audit --check`. Note it is already Ansible-Vault-encrypted
   in `group_vars/openclaw.yml`, so this is at-rest exposure on the host, not in git.
2. **Gateway is bound to `0.0.0.0`** ("lan", network-accessible). Combined with
   `openclaw_allow_insecure_ws: true` in the node role defaults, node traffic carries that
   token over the LAN unencrypted. Doctor suggests keeping the bind on loopback and
   fronting it with an SSH tunnel or Tailscale Serve.
3. **No command owner is configured.** Without `commands.ownerAllowFrom`, no account is
   authorized to approve exec approvals or run owner-only commands. This connects to the
   capability question below: nodes hold `system.run`, and re-approvals want
   `system.execApprovals.set`, with no designated human gating any of it.

## TODO — read plane, unscheduled

1. **Harden `openclaw-node.service`** so read-only is kernel-enforced rather than a
   side effect of lacking sudo — `ProtectSystem=strict`, `ProtectHome=read-only`,
   `ProtectKernelTunables=true`, `PrivateDevices=true`, with `ReadWritePaths` for
   `~openclaw/.openclaw` and the log directory. Needs a `validate-openclaw.yml` run behind
   it before going fleet-wide; the paths the node actually writes are not fully enumerated.
2. **Audit the other identities** the same way. `lfoss` and `ansible` hold
   `(ALL) NOPASSWD: ALL` by design, but the sweep above only asked about `openclaw`.
3. **Decide whether the read plane extends to the capability layer** — see "What this does
   not cover" above.

These are write-plane changes: they belong in the roles, applied by playbook, never
hand-edited on the hosts.

## Related

- [`claude-access.md`](claude-access.md) — the scoped `claude` → `ansible` escalation, the
  model item 1 should follow
- `../README.md` — topology, playbooks, version pinning
