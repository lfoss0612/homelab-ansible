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

## Sandboxing openclaw-node.service

Removing the sudo grant stopped the agent becoming root. It did **not** make it
read-only: as the `openclaw` user it could still write its own `$HOME`, its
`~/.config/systemd/user` manager (the exact directory the 2026-08-08 legacy-unit
purge had to clean out), and any world-writable path on the box. The read plane was a
property of what the identity happened to lack, not something the kernel enforced.
`openclaw_node_hardening` closes that gap in the unit itself:

```
ProtectSystem=strict     ProtectHome=read-only
ProtectKernelTunables=true    PrivateDevices=true
ReadWritePaths=/home/openclaw/.openclaw
ReadWritePaths=-/var/log/openclaw
```

This binds whatever the *agent* is told to run, not just the node process — nodes hold
`system.run` at the gateway, so every command the gateway dispatches inherits it.

**The writable set was measured, not guessed.** The blocker on this item was always
that nobody had enumerated what a node actually writes. Read live on 2026-08-08 from
the open write file descriptors of every running `openclaw-node` in the fleet, the
answer was identical on all 14 hosts and shorter than expected: the Memory Core SQLite
and its `-wal`/`-shm` siblings under `.openclaw/state/`, and nothing else. Node's
compile cache lands in `/tmp`, which `PrivateTmp=true` already made private. So two
`ReadWritePaths` entries cover the fleet, and `openclaw_node_hardening_extra_rw` exists
for a host that ever needs a third rather than as something to populate now.

`/var/log/openclaw` is `-` prefixed (tolerate-if-absent) because nothing was observed
writing to it — output goes to the journal. The state directory deliberately is not: a
missing Memory Core should fail the unit at start, not run unwritable.

**`PrivateDevices=true` costs one real capability, and it is handed back explicitly.**
It replaces `/dev` with API pseudo-devices only, which breaks `zpool status` / `zfs
list` — genuine storage observability on `pve`, `pve-ai`, `pve-router`, `pbs` and
`omv`, and today's only in-agent health signal on the backup server. Restoring it
needs **both** of these, and neither works alone (verified on `pve` 2026-08-08 — each
by itself still fails `/dev/zfs and /proc/self/mounts are required`):

```
DeviceAllow=/dev/zfs rw          # satisfies the cgroup device filter
BindReadOnlyPaths=/dev/zfs       # creates the node inside the private /dev
```

`DeviceAllow` alone is not enough on cgroup v2: the BPF device filter permits the
device, but systemd does not populate a node for it in the private `/dev`. A bind
mount alone creates the node and is then refused by the filter. The role **detects**
`/dev/zfs` per host rather than reading a group_vars list, because the ZFS hosts span
`proxmox_hosts`, `bare_metal` and `qemu_vms` — there is no group that means "has ZFS" —
and a host that gains or loses ZFS later self-corrects on the next run.

Worth being explicit about what this is not: `/dev/zfs` is `crw-rw-rw-`, so any
unprivileged user on those hosts can already issue read-only ZFS ioctls. Handing it
back keeps the status quo; it does not grant the agent anything it lacked.

**Rolled out opt-in per host, then defaulted on** (2026-08-08), the same shape as
`openclaw_resolved_standardize` and `openclaw_networkd_standardize` — `zabbix` canaried
the plain path, `pbs` the ZFS one, both went through a clean `validate-openclaw.yml`,
and `openclaw_node_hardening` then became the default. The variable stays so a host
that ever needs the sandbox off can say so in `host_vars` rather than by hand-editing a
unit that self-heals on the next deploy.

The canary run corrected the detection: `zabbix` has `/dev/zfs` because the ZFS module
is loaded, but no `zpool` binary at all, so the first version handed the device back
into a sandbox where nothing on the host could use it. Detection now requires the
device **and** a userspace tool.

Before either canary was touched, the full read-plane command
battery (`journalctl`, `systemctl`, `ss`, `ps`, `lsblk`, `ip`, `df`, `free`, `smartctl
--scan`, `zpool`, `crictl`, `qm`/`pct`/`pvesm`) was run inside a transient unit
carrying these exact properties on `zabbix`, `pve`, `pve-ai` and `k8s-worker`, against
an unsandboxed control run of the same battery. Only `zpool` regressed. Everything else
that failed, failed identically both ways — `qm`/`pct`/`pvesm` want root and have not
had it since the sudo grant was removed, which is the point.

`validate-openclaw.yml` asserts the sandbox from `systemctl show`, not from the unit
file, so it catches the specific drift a file check cannot: a unit rewritten but never
restarted, still running unsandboxed. It asserts the two ZFS directives as properties
too rather than running `zpool` and checking it works — anything the play executes runs
as `ansible`, outside the sandbox, so a live call would pass no matter what the unit
says.

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

## pve-router — out-of-band recovery path

`pve-router` joined `openclaw_nodes` 2026-08-04 (see the DNS resolver assertion section
above) via the same `openclaw_nodes`/`deploy-openclaw.yml` path as every other Proxmox
host, no special-casing. That host is higher-risk than the rest of the fleet: it's the
hypervisor for the OPNsense VM that the whole house network routes through, and for
`cockpit`, the Ansible control node itself. A bad play here can take down the network and
the control path used to fix it in the same stroke. `homelab-vault` `TODO.md`'s "Bring
pve-router and OPNsense under Ansible management" item requires a documented,
network-independent recovery path *before* any write-capable play is allowed to target
this host — that's now written up in the vault, not duplicated here: see
`Proxmox/ops/pve-router-recovery.md` (direct Proxmox-UI-over-a-patched-cable as primary,
physical console as fallback; documented 2026-08-04 and since rehearsed end-to-end).

With that documented, the precondition the TODO called for is met for the *access* half of
the risk.

**The execution-model half is now implemented too, scoped down from a separate playbook
path to a procedural + technical gate (2026-08-04):**

- **Procedural:** any write-capable play targeting `pve-router` should get a mandatory
  `--check --diff` dry run first, read by a human, before running live — same practice
  that already caught real bugs during the DNS/networkd rollouts above. Not enforced by
  tooling; a discipline to follow.
- **Technical:** `playbooks/tasks/confirm-pve-router.yml` is a reusable gate — `meta:
  end_host` for `pve-router.home.lan` unless `-e confirm_pve_router=true` is passed,
  with a `debug` report first so a skip is visible in the run output, not silent.
  Imported as the first task of every write-capable play whose host pattern can include
  `pve-router.home.lan`: `deploy-openclaw.yml` (the nodes play), `bootstrap/install-acl.yml`,
  `bootstrap/nodesource-repo.yml`, `users/ansible-user.yml`, `users/lfoss-user.yml`,
  `users/disable-requiretty.yml`. `decommission-openclaw-node.yml` gets an explicit
  `assert` instead (louder failure, appropriate for a single-named-target playbook rather
  than a fleet sweep). Read-only plays (`validate-openclaw.yml`) don't need it.
- **Deliberately not gated: `update-openclaw.yml`.** That's the weekly-timer path, and
  `pve-router`'s automatic weekly convergence there is an already-made decision
  (2026-08-04), not an accidental sweep — gating it would silently stop `pve-router` from
  ever auto-updating. See `TODO.md` for the planned replacement: an ntfy push notification
  with an approval button that triggers a confirmed run, rather than either blind
  auto-convergence or blind skipping.

**LXC/pct config automation is now implemented** (2026-08-05): `playbooks/proxmox-config.yml`
reads current config, compares against declared state in `host_vars`, and runs `pct set` only
for settings that differ — idempotent and safe with `--check --diff`. The concrete forcing
case (cockpit/pdm nameserver fixing DNS resolution) is covered.

**`qm` config, a denylist, and a per-guest gate followed** (2026-08-07). Three things
changed:

- The comparison in `tasks/proxmox-apply-config.yml` was rewritten from `when`-driven to
  data-driven. The old form compared a regex-extracted first line against `value | string`
  inside the apply task's `when:`, which had four failure modes — all latent only because
  the single consumer was a one-token `nameserver`. A boolean (`onboot: true` → `"True"`
  vs. Proxmox's `1`) never compared equal and would have re-applied on every run forever;
  a space-separated value was split into separate argv elements so it could never land;
  property strings compared unequal on ordering alone; and multi-line `description`
  continuation lines could be mis-read as config keys. The rewrite parses into a map,
  canonicalises (booleans → `1`/`0`, property strings sorted, whitespace collapsed but
  **order preserved**, since `nameserver` is an ordered preference list), builds an explicit
  diff list, reports it under `--check`, and applies with `argv`. Idempotence is now a
  property of the diff list being empty. There is no regex, so the injection surface is
  gone too.
- `tasks/proxmox-assert-safe-keys.yml` refuses any declared key matching a
  hardware/boot/storage prefix denylist — `hostpci*` (OPNsense's igc0/igc1/igc2
  passthrough), `scsi*`/`sata*`/`ide*`/`virtio*`/`nvme*`/`rootfs`/`mp*`/`unused*`/`efidisk*`,
  `net*` (which for `pct` would sever cockpit from itself), `boot*`/`bios`/`machine`/
  `ostype`/`arch` (VM 106 is OVMF/q35 — a flip there bricks boot silently until next
  start), plus `args`, `tpmstate*`, `smbios*`, `vmgenid`, `cipassword`, `template`, and
  `description` (which cannot be safely compared, so it must not be declarable). These are
  `assert` tasks specifically because `assert` is pure-Python and fires identically under
  `--check`; a `fail` guarded by a `command` probe would be skipped in check mode and the
  gate would silently pass. `protection` is deliberately *not* on the denylist — declaring
  `protection: 1` gives drift detection on the most important safety flag on VM 106 — but a
  companion assert refuses any attempt to set it to a false value. Ansible may turn
  protection on, never off.
- `proxmox_protected_vmids` adds a second, narrower gate: `confirm_pve_router=true` unlocks
  the *host*, `confirm_protected_vmids=true` unlocks the listed *guests* on it. Report-then-
  skip, matching `confirm-pve-router.yml`, so a default run still converges everything else
  and simply reports what was held back.

The first `proxmox_qm_config` consumer (VM 106) is deliberately a **no-op**: every declared
value is already true on the live VM, so a correct run reports zero changes. It exercises
the read/parse/compare path with no write risk while converting four facts that lived only
in the Proxmox UI into git-tracked declared state.

VM lifecycle, storage, and PBS/backup-job configuration remain unstarted; see `TODO.md`.

## OPNsense — write plane is the REST API, not SSH

Recorded here so the decision is not relitigated. Classic SSH+Python Ansible — the pattern
every `openclaw/node` role uses — **does not fit OPNsense**:

- SSH lands in a locked-down console menu. A root shell is reachable via option 8, but
- it is a FreeBSD appliance with **no Python**, and
- config lives in a single XML file managed by OPNsense's own backend, not in the
  individual files the standard modules edit.

Manually `pkg install`-ing Python to force the standard modules to work fights the appliance
model and risks being wiped by a firmware upgrade — the same objection that keeps `haos`
out of the inventory entirely. The write plane is therefore its **REST API**, called from
the control node with a dedicated API key.

Staged read-only first, deliberately:

1. **Connectivity + drift detection** (`opnsense-facts.yml`) and **config backup**
   (`opnsense-backup-config.yml`) use `ansible.builtin.uri` and depend on no third-party
   collection at all. All of the read-only value therefore survives even if the collection
   turns out to be unsuitable.
2. **Exactly one object type is writable** (`opnsense-unbound.yml`: Unbound host overrides,
   create and update only). Everything else — firewall rules, aliases, NAT, interfaces,
   HAProxy, VPN, the internal CA, ACME — stays manual. There is **no delete path** in the
   repo, and the ~43 overrides that are not declared are reported and never touched, because
   five of the six pages of them have never been reviewed by a human.

Two endpoint facts worth recording, both verified 2026-08-06 rather than assumed:

- **The API is reached through HAProxy at `opnsense.home.lan`, not directly at
  `10.0.5.1:8443`.** That direct listener presents the *public* ACME wildcard
  `*.fosshomelab.duckdns.org` (issuer: Let's Encrypt), whose only SAN is that DNS name — so
  it cannot be validated by IP nor against the internal CA, and the duckdns name itself
  resolves to the WAN address. HAProxy's frontend serves the internal `*.home.lan` leaf,
  which validates against the CA this repo already ships. The accepted tradeoff is that API
  calls managing the resolver route through a name that resolver answers for; that is
  tolerable because the documented rollback is the GUI **by IP**, which needs no DNS and is
  guaranteed reachable from the LAB VLAN by OPNsense's own anti-lockout rule. The recovery
  path never depended on Ansible.
- **There is no dry-run/validate endpoint for Unbound**, unlike `openclaw config patch
  --dry-run` which the models role leans on. That is a real gap in the safety model. What
  compensates for it: a validated `config.xml` backup is taken before the first write and
  **the writes skip entirely if that backup fails**, and after the change a real `dig`
  proves DNS still resolves — because `reconfigure` can return 200 and still leave Unbound
  dead. On failure the play fails loudly naming the restore path rather than attempting an
  automatic rollback; pushing a whole config.xml back through an appliance whose state is
  now unknown is under-specified, and a half-applied restore is worse than a clean manual
  one.

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

`openclaw-node.service` is now sandboxed — see "Sandboxing openclaw-node.service"
above, done 2026-08-08. The three remaining items — audit the other identities, decide
on the capability layer, and create the Zabbix trapper — are tracked in the
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
