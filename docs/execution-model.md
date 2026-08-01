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

## Current state — the split is NOT yet enforced

An audit on 2026-08-01 (`ansible openclaw -m shell -a 'id openclaw; sudo -l -U openclaw'`)
found that **every node grants the `openclaw` user passwordless sudo, and none of it is
managed by this repo.** These sudoers files predate the npm rewrite and are not in git.

| Hosts | Grant |
|---|---|
| `pve`, `pve-ai`, `omv`, `zabbix`, `pdm`, `cockpit`, `pbs`, `vscode`, `k8s-master`, `k8s-worker`, `k8s-worker-2` | `(ALL) NOPASSWD: /usr/bin/systemctl` |
| `openclaw` (gateway) | `(root) NOPASSWD: /bin/systemctl restart openclaw-gateway`, `status openclaw-gateway` |

Unrestricted `systemctl` as root is **a full root escalation**, not a service-restart
grant: `openclaw` owns its home directory, so `systemctl link ~/unit.service && systemctl
start unit` runs arbitrary code as root. Eleven of twelve nodes are therefore root-capable
today. Only the gateway's grant is correctly scoped.

The `openclaw` user is otherwise clean — a system account, no supplementary groups
(except `_ssh` on `omv`), and `openclaw-node.service` already sets `NoNewPrivileges=true`.

## Revoking the grant — implemented, not yet applied

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
identity, not as `openclaw`. What may depend on it is the **agent's own runtime ability to
restart its service** — that is precisely the write-plane capability being withdrawn, but
it means any existing OpenClaw workflow that restarts a unit will begin to fail, by design.

Apply with a dry run first, gateway included. **Use `--tags privileges`** — an untagged
run would also fire `common`'s npm install task, dragging all 11 nodes from `2026.5.26` to
the pinned `openclaw_version` as a side effect of a security fix, with none of
`update-openclaw.yml`'s health gates:

```bash
ansible-playbook playbooks/deploy-openclaw.yml --tags privileges --check --diff
```

Then re-audit to confirm both halves — no root, but logs readable:

```bash
ansible openclaw -m shell -a '
  id -nG openclaw
  sudo -l -U openclaw 2>&1 | tail -2
  runuser -u openclaw -- journalctl -u ssh -n 1 --no-pager 2>&1 | tail -1'
```

Expect `openclaw systemd-journal adm`, a "may run" list that is empty or absent, and a
real log line from a unit the agent does **not** own.

`pve-router` is not in `openclaw_nodes`, so its own `openclaw` user keeps whatever grant it
has. That host is independently managed and deliberately out of scope.

## TODO — remaining

1. **Harden `openclaw-node.service`** so read-only is kernel-enforced rather than a
   side effect of lacking sudo — `ProtectSystem=strict`, `ProtectHome=read-only`,
   `ProtectKernelTunables=true`, `PrivateDevices=true`, with `ReadWritePaths` for
   `~openclaw/.openclaw` and the log directory. Needs a `validate-openclaw.yml` run behind
   it before going fleet-wide; the paths the node actually writes are not fully enumerated.
2. **Audit the other identities** the same way. `lfoss` and `ansible` hold
   `(ALL) NOPASSWD: ALL` by design, but the sweep above only asked about `openclaw`.

These are themselves write-plane changes: they belong in the roles, applied by playbook,
never hand-edited on the hosts.

## Related

- [`claude-access.md`](claude-access.md) — the scoped `claude` → `ansible` escalation, the
  model item 1 should follow
- `../README.md` — topology, playbooks, version pinning
