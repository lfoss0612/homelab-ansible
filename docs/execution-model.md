# Execution model — read plane vs write plane

Standing decision, 2026-08-01. Fleet work is split by **verb**, not by host.

| Plane | Tool | Scope |
|---|---|---|
| **Read** | OpenClaw nodes (13 hosts) | Observe, tail logs, inspect running state, debug interactively. No host mutation. |
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

`pve-router` joined `openclaw_nodes` 2026-08-04, so this privileges assertion now runs
against it too on the next converge — its `openclaw` user's grant will be brought in line
with the rest of the fleet rather than left as-is.

## DNS resolver assertion

Added 2026-08-03, same `common` role, same `--tags` mechanism as `privileges`
above — added here rather than as its own doc because the split (`privileges`
tags gate root-adjacent changes, `dns` tags gate resolver changes) follows the
exact same pattern.

### What was found

`homelab-vault` `TODO.md` (2026-08-02) records three DNS misconfigurations
found by hand while debugging node reconnection after the HAProxy migration,
none of them git-tracked:

| Host | Problem |
|---|---|
| gateway | Stale self-referential `/etc/hosts` entry (`10.0.5.7 openclaw.home.lan`, predating the HAProxy migration), causing the gateway's own node instance to try connecting to itself on `:443` instead of resolving through Unbound. |
| `pbs` | Static, `chattr +i`-immutable `/etc/resolv.conf` pointed at `10.0.5.2` (`pve-router`, not a DNS server), with public fallbacks that don't know `.home.lan`. |
| `pve-ai` | Correct per-link `DNS=10.0.5.1` in `/etc/systemd/network/10-vmbr0.network`, shadowed by a global `DNS=8.8.8.8 1.1.1.1` override in `/etc/systemd/resolved.conf`. |

OPNsense/Unbound was confirmed correct in all three cases — every failure was
a local override bypassing it, not a bad answer from OPNsense itself. A
rebuild of any of these three hosts would have reintroduced the exact same
breakage.

### How it's fixed

Independently-gated tasks in `common`, each a no-op on a host that doesn't
have the specific problem. Two are auto-fixed; the third is report-only:

- An immutable `resolv.conf` (the `pbs` case) is corrected in place —
  `chattr -i`, rewritten to `nameserver {{ openclaw_dns_resolver }}`,
  `chattr +i` restored — only when its content doesn't already match. A
  non-immutable `resolv.conf` is left alone; those track DHCP-learned
  per-link DNS correctly on their own.
- A global `DNS=` override in `resolved.conf` or a `resolved.conf.d/*.conf`
  drop-in (the `pve-ai` case) is *removed*, not replaced, so the correct
  per-link DHCP value wins instead of hardcoding a second place the resolver
  IP has to be kept in sync. Only acts when `systemd-resolved.service` is a
  known service on the host. Confirmed against the live fleet via
  `--check --diff` before this was ever applied for real — and it caught a
  **4th, previously undocumented instance on `pve`** (same `DNS=8.8.8.8
  1.1.1.1` override as `pve-ai`), so this wasn't just re-encoding the three
  already-known cases.
- A non-loopback `/etc/hosts` line containing the host's own inventory
  hostname (the gateway case) is **reported, not removed**. The first
  version of this auto-removed it, but a `--check --diff` run against the
  live fleet showed that was wrong: `k8s-worker` and `pve` both have exactly
  this pattern with a correct, current IP — it's normal provisioning output
  (fast local self-resolution before DNS is up), not a bug. The gateway's
  actual failure was narrower — its own node process needed to route to
  itself *through HAProxy*, and a same-named entry pointing straight at its
  own LAN IP bypassed that — which isn't reliably distinguishable from the
  benign case without knowing about that specific routing requirement. So
  this one stays a human judgment call, same as the doctor-warnings pattern
  in `validate-openclaw.yml`.

`openclaw_dns_resolver` (`common/defaults/main.yml`) defaults to
`ansible_default_ipv4.gateway` — OPNsense is both router and resolver on
every VLAN in this network, so the host's own default gateway is a correct,
subnet-agnostic stand-in for "the right nameserver" with no per-VLAN table to
maintain.

### Applying it

Same dry-run-first discipline as `privileges`:

```bash
ansible-playbook playbooks/deploy-openclaw.yml --tags dns --check --diff
```

Expect `changed` only on hosts that actually have one of the three problems;
everything else should show `changed=0`.

**Not part of the weekly timer.** Like `privileges`, this only runs inside
the node/gateway roles, which `update-openclaw.yml` only re-enters via
`openclaw_update_required` — a host already at the pinned version skips the
role entirely, `common` included. Once the fleet is converged, a `--tags dns`
run has to be triggered manually (or added to the timer's playbook list
separately) to catch a rebuilt or newly-added host.

### Verifying

```bash
ansible openclaw -m shell -a 'resolvectl status 2>/dev/null | grep "DNS Server" || cat /etc/resolv.conf'
```

Every host should show the same resolver family it started with (its own
VLAN's OPNsense IP) — not a public resolver, not a stale LAN IP.

`pve-router` joined `openclaw_nodes` 2026-08-04, so the DNS resolver assertion now runs
against it too on the next converge — same change as `privileges` above.

## The unattended arm of the write plane

Since 2026-08-01 the write plane has an automated arm: `openclaw-fleet-update.timer` on
cockpit, installed by `playbooks/openclaw-automation.yml` (role
`openclaw.node.control`). First end-to-end run 2026-08-02 01:29 UTC — 13 hosts,
`failed=0`, `last-success` recorded at commit `486afcf`. Weekly, as the `ansible` user,
it runs

```
git -C /opt/ansible pull --ff-only
ansible-playbook playbooks/update-openclaw.yml
ansible-playbook playbooks/validate-openclaw.yml
```

and only then records `/var/lib/openclaw-fleet-update/last-success`
(timestamp, commit, pinned version). This does not weaken the rule above — it
strengthens it. The timer runs *playbooks from git and nothing else*; it has no
way to make a change that isn't already committed, and it never writes a
tracked file. Bumping the version is still a human commit to
`group_vars/openclaw.yml`; the timer's only job is drift correction.

Four properties are deliberate:

- **It reads the pin, never writes it.** Its predecessor, `openclaw-sync.timer`,
  `sed`-ed the new version into `group_vars` *before* running the rollout. When the
  rollout died on 2026-06-04 the recorded version already matched, so the next poll
  logged "Versions match. Nothing to do." The failure erased its own evidence and the
  fleet sat un-upgraded for two months.
- **State is recorded only after every playbook exits 0**, and validation is one of
  them — a fleet that installed the pin but fails its health checks leaves the unit
  failed rather than recording a green run.
- **It runs as `ansible`, not root.** `ansible.cfg` points `local_tmp`/`remote_tmp` at
  `/home/ansible/.ansible/tmp`, so a root-run playbook leaves root-owned files that
  break every later run as that user. Past root-run syncs are why the role has to
  repair `/opt/ansible`'s permissions at all: they left 163 root-owned paths under
  `.git` with `2755` object fanout dirs, and `git pull` as `ansible` failed with
  "insufficient permission for adding an object to repository database". The role
  fixes ownership and sets `core.sharedRepository=group` so it cannot re-accumulate.
- **Weekly, not every five minutes**, and `flock`-guarded so a manual run and a timer
  firing can never interleave two serialized rollouts.

Failure surfaces as a failed unit — `systemctl status openclaw-fleet-update.service`,
`journalctl -u openclaw-fleet-update.service` — and, since 2026-08-02, as an active
notification: the unit carries `OnFailure=`/`OnSuccess=` into
`openclaw-fleet-update-notify@.service`, which records a `last-failure` file, pushes
1/0 to a Zabbix trapper and optionally POSTs to a webhook. See the README for the
mechanism and the one-time Zabbix item that still has to be created server-side.

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

## TODO — gateway security, next up

Deferred by decision on 2026-08-01 behind the cockpit convergence timer, which is now
installed and verified end to end — so these are next. All three surfaced from
`openclaw doctor --lint` on the gateway, which only started running once
`validate-openclaw.yml` was fixed — nothing had been checking.

They now also fail *weekly and unattended*: `validate-openclaw.yml` runs from the timer
and reports these as warnings on every pass. They do not fail the run (warnings are
reported, only errors gate) but they are no longer findable solely by someone
remembering to look.

**None of them are Ansible fixes.** They are `openclaw config` / `openclaw secrets`
changes on the gateway, so keeping them in git means either a new role that templates
gateway config or a documented runbook. Applying them by hand leaves no record, which is
the exact failure this whole document exists to prevent.

The three items — the plaintext `gateway.auth.token`, the `0.0.0.0` bind combined with
`openclaw_allow_insecure_ws: true`, and the missing `commands.ownerAllowFrom` owner — are
tracked in the homelab-vault `TODO.md`, under "OpenClaw — gateway security". The third
connects to the capability question below: nodes hold `system.run`, and re-approvals want
`system.execApprovals.set`, with no designated human gating any of it.

## TODO — read plane, unscheduled

~~**Give `openclaw-fleet-update` a failure notification path.**~~ **Done 2026-08-02**,
and not a moment early: the concern was hypothetical when it was written, and the very
first scheduled run (2026-08-02 03:46) then died in `git pull` and told nobody. It was
found only by reading the journal by hand, days later, by which point systemd had
dropped even the failed state. Cause: the sync command documented in `CLAUDE.md` ran
the git module as root — `ansible.cfg` sets `become = True` — leaving root-owned
objects the `ansible` user could not write. Both are fixed; see the convergence
section above and `CLAUDE.md`.

**One piece remains outstanding**: the Zabbix trapper item `openclaw.fleet.update` and
its two triggers must be created on host `cockpit.home.lan` (spec in the README). Until
then the server accepts each value and discards it, and only the `last-failure` file
and the optional webhook do anything.

The four remaining items — harden `openclaw-node.service`, audit the other identities,
decide on the capability layer, and create the Zabbix trapper — are tracked in the
homelab-vault `TODO.md`, under "OpenClaw — read plane". These are write-plane changes:
they belong in the roles, applied by playbook, never hand-edited on the hosts.

## TODO — cleanup, unscheduled

Everything the migration deliberately left in place, because a rollback path was worth
more than the disk. The fleet is converged and validated, so the reason to keep it has
expired. **This is write-plane work too** — a playbook with an explicit gate, not a
`for host in ...; do ssh rm -rf; done`.

The five cleanup items — 58.1 GB of dead `/opt/openclaw` trees, `/srv/openclaw`
tarballs, the `openclaw-artifacts` nginx site, moved-aside `.pre-npm.disabled`
wrappers, and the unapproved `Lester's S23 Ultra` device — are tracked in the
homelab-vault `TODO.md`, under "OpenClaw — cleanup", along with per-host disk
measurements.

## Tracked in the other repo

Not Ansible's to fix, recorded here only so the list is complete. Both live in
`homelab-gitops` and predate the fleet work:

- `CLAUDE.md` is untracked — commit it or add it to `.gitignore`.
- `argocd/open-webui/open-webui.yaml` has uncommitted local changes. Under `selfHeal: true`
  an uncommitted manifest is a change that does not exist as far as the cluster is
  concerned; decide whether it ships or gets reverted.

## Related

- [`claude-access.md`](claude-access.md) — the scoped `claude` → `ansible` escalation, the
  model item 1 should follow
- `../README.md` — topology, playbooks, version pinning
