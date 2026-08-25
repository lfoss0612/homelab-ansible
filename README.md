# homelab-ansible

Control-node repo for the homelab's Ansible-managed hosts. Lives at `/opt/ansible` on
`cockpit.home.lan`, the control node; this checkout is a clone relayed to GitHub from a
workstation, since cockpit has no push credentials.

## Topology

14 inventory hosts total (`inventory.ini`):

- **`proxmox_hosts`** — `pve`, `pve-ai`, `pve-router` (three hypervisors).
- **`qemu_vms`** — `omv`, `zabbix`, `vscode`, `openclaw` (the gateway VM), `desktop`.
- **`lxc`** — `cockpit`, `pdm`. Both are unprivileged LXC containers on `pve-router`, not
  QEMU VMs — split out of a single `vms` group 2026-08-03 because Proxmox's `pct` tooling
  writes `/etc/resolv.conf` directly into the container rootfs from host-side config on
  every start, overriding anything set inside the guest (including `systemd-resolved`'s
  own stub symlink). See `homelab-vault` TODO.md, "Standardize the fleet on
  systemd-resolved". **The host-side `pct` config is now managed by
  `playbooks/proxmox-config.yml`**, which applies the declared nameserver to both containers
  on `pve-router` — the actual `/etc/resolv.conf` inside each guest updates on the next
  container start.
- **`bare_metal`** — `pbs`. Physical, not virtualized (also previously miscategorized
  under `vms`).
- **`k8s_master` / `k8s_workers`** (parent group `k8s`) — `k8s-master`, `k8s-worker`,
  `k8s-worker-2`.

### OpenClaw fleet

`openclaw_nodes` = `openclaw_proxmox` (`pve`, `pve-ai`, `pve-router`) + `qemu_vms` + `lxc` +
`bare_metal` + `k8s` — **14 hosts**.
`openclaw.home.lan` (the gateway) is a deliberate member: it runs both
`openclaw-gateway.service` and `openclaw-node.service`, managing its own VM as well as
brokering the rest of the fleet.

**`pve-router` joined `openclaw_nodes` 2026-08-04.** It already ran a live,
independently-managed OpenClaw node (`openclaw-node.service`, registered with the gateway)
that this repo previously never touched; it now converges through the same
`deploy-openclaw.yml`/`update-openclaw.yml`/`validate-openclaw.yml` path as every other
node, including the weekly `openclaw-fleet-update` timer. This host hosts the OPNsense VM
the whole house network runs on — see `homelab-vault` TODO.md, "Bring `pve-router` and
OPNsense under Ansible management", for the broader (still unscheduled) risk writeup about
managing the *hypervisor itself*; that concern is separate from the openclaw-node agent
covered here.

**`openclaw_optional`** (currently just `desktop`) is a behavioural overlay on top of the
topology groups, not a separate tier: those hosts are full `openclaw_nodes` and are
converged identically, but they are legitimately powered off part of the time, so no play
may treat *unreachable* as a failure for them. `deploy-openclaw.yml`,
`update-openclaw.yml` and `validate-openclaw.yml` therefore run their strict pass over
`openclaw_nodes:!openclaw_optional` and pick these hosts up in a second play with
`ignore_unreachable: true`; `validate-openclaw.yml` also subtracts them from its
connected+paired assertion and reports them instead. Without this the weekly
`openclaw-fleet-update` timer would go red every time a desktop was switched off.

### Hosts Ansible does not manage

**`haos`** (VMID 112 on `pve`, `10.10.5.3`) runs **Home Assistant OS 18.0**, an immutable
appliance image: no apt, read-only `/usr`, no persistent `useradd`, nowhere to install a
systemd unit, and no sshd on either 22 or the 22222 debug port. It can never be an
Ansible-managed OpenClaw node, and it is deliberately **absent from `inventory.ini`** —
listing it would add nothing but an unreachable host to every `hosts: all` play. The only
viable route to an OpenClaw presence there is a Home Assistant add-on (a container managed
by the HA supervisor), which is outside this repo's write plane. `inventory.ini` carries a
comment where it would otherwise go, and
`playbooks/bootstrap/bootstrap-vm-guest-agent.yml` refuses any guest whose agent reports
an OS id outside `debian`/`ubuntu` — HAOS reports `haos`.

### Appliances managed over an API

**`opnsense`** (VM 106 on `pve-router`, LAB address `10.0.5.1`) is a third category,
distinct from both the SSH-managed fleet above and from `haos` immediately preceding: it
**is** in `inventory.ini`, but it has no SSH/Python transport at all.

SSH into OPNsense lands in a locked-down console menu, and it is a FreeBSD appliance with
no Python — `pkg install python` to force the standard modules to work fights the appliance
model and gets wiped by firmware upgrades, the same objection that excludes `haos`
entirely. Its write plane is instead its **REST API**, which is already proven (the traffic
shaper was reconfigured through it on 2026-07-13).

It is listed because a named inventory host is the only way to get `host_vars` auto-loading
— see `host_vars/opnsense.home.lan.yml`. Two groups carry it:

- **`[network_appliances]`** — the topology group. `group_vars/network_appliances.yml`
  sets `ansible_connection: local` (every task runs on cockpit and talks HTTP) and
  `ansible_become: false`.
- **`[api_managed]`** — a behavioural overlay. **Every `hosts: all` play must subtract it**
  (`hosts: all:!api_managed`). Because the connection is `local`, an `apt`/`useradd` task
  aimed at this host does not fail — it *succeeds*, silently, against the control node.
  The four affected plays (`users/ansible-user.yml`, `users/lfoss-user.yml`,
  `users/disable-requiretty.yml`, `bootstrap/install-acl.yml`) already do this.

`become: false` is set both as a play keyword on every OPNsense play and as a group var,
deliberately redundantly: `ansible.cfg` sets `become = True` globally, which would otherwise
sudo every API call to root on cockpit.

Scope is deliberately narrow. Reads (`opnsense-facts.yml`, `opnsense-backup-config.yml`)
use `ansible.builtin.uri` and depend on **no third-party collection**, so all read-only
value survives even if the collection proves unsuitable. Only the single write play uses
`oxlorg.opnsense`. Firewall rules, aliases, NAT, interfaces, HAProxy, VPN, the internal CA
and ACME are all **out of scope and stay manual**, and there is **no delete path** for
Unbound overrides anywhere in this repo.

Roles live in `collections/ansible_collections/openclaw/node/roles/`:

- **`common`** — shared install surface: Node.js floor (`openclaw_node_min_version`,
  guarded on installed version, not repo rewrite), `openclaw` user/group, log/state dirs,
  CLI-path collision handling, and `npm install -g openclaw@{{ openclaw_version }}`.
- **`gateway`** — backs up `~openclaw/.openclaw`, installs `common`, templates
  `openclaw-gateway.service`, health-gates on `/health` returning `{"ok":true}`.
- **`node`** — installs `common`, templates `/etc/default/openclaw-node` (gateway token +
  `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS`) and `openclaw-node.service`.
- **`control`** — control-node only (group `openclaw_control` = cockpit): installs the
  weekly `openclaw-fleet-update` script/service/timer plus its `OnFailure`/`OnSuccess`
  notifier, repairs `/opt/ansible` so the `ansible` user can `git pull` unattended, and
  removes the legacy `openclaw-sync` units.

The CLI is npm-installed fleet-wide; there is no more per-host source build or
`releases/current/shared` directory tree.

## Execution model

OpenClaw nodes are the **read plane** (observe, tail, debug); Ansible is the **write
plane** for hosts; Argo CD is the write plane for anything in-cluster. Changes found by
debugging on a host are fixed by a playbook here, never by hand on the host. See
[`docs/execution-model.md`](docs/execution-model.md) — including the audit that found
root-equivalent sudo on all 12 hosts, how the roles revoke it, and the unattended arm
(`openclaw-fleet-update.timer`) that runs playbooks from git on a weekly schedule.

## Playbooks

| File | Purpose |
|---|---|
| `playbooks/proxmox-config.yml` | Apply declarative Proxmox `pct`/`qm` config to LXC containers and VMs. Reads current config, parses and canonicalises it, and applies only the settings that actually differ — booleans, property-string ordering and multi-valued settings all compare correctly, and the apply uses `argv` so values containing spaces are passed as one argument. Idempotent; safe with `--check --diff`, which reports the pending diff rather than staying silent. **Skips `pve-router` unless `-e confirm_pve_router=true`**, and additionally skips any VMID in `proxmox_protected_vmids` (VM 106 / OPNsense) unless `-e confirm_protected_vmids=true`. Every declared key is checked against a hardware/boot/storage **denylist** (`tasks/proxmox-assert-safe-keys.yml`) which refuses `hostpci*`, `scsi*`, `net*`, `boot*`, `efidisk*` and more, and refuses any attempt to set `protection` to a false value. Config declared per-host in `host_vars` as `proxmox_lxc_config`/`proxmox_qm_config` lists. |
| `playbooks/opnsense-facts.yml` | **Read-only.** Probes the OPNsense API, then reports Unbound host-override drift against the managed subset in `host_vars/opnsense.home.lan.yml`. Writes nothing, and is not gated on any confirm flag. Entries on the box that are not declared are reported and never touched. |
| `playbooks/opnsense-backup-config.yml` | Download OPNsense's full `config.xml` to `/var/backups/opnsense` on cockpit (0700 dir, 0600 root-owned files), validate it is real XML, and prune to the newest 14. **The file contains the internal CA's private key** — it must never reach git. Also included by the write play as its pre-write rollback artefact. |
| `playbooks/opnsense-unbound.yml` | The **only** play that writes to OPNsense. Converges the managed subset of Unbound host overrides (create/update only — no deletes). Requires all three gates: `opnsense_unbound_overrides_manage: true`, `opnsense_unbound_overrides_enforce: converge`, and `-e confirm_opnsense_write=true`; a closed gate reports and skips. Takes a validated `config.xml` backup first and **skips every write if that backup fails**. Reconfigures Unbound once via a handler, then re-reads to assert the writes landed and runs a real `dig` to prove DNS still resolves — failing loudly with the restore path rather than attempting an automatic rollback. |
| `playbooks/bootstrap/opnsense-api-deps.yml` | Install `python3-httpx` on the control node for the `oxlorg.opnsense` collection. Uses the distro package, not pip — Debian 13 is PEP-668 externally-managed. |
| `playbooks/deploy-openclaw.yml` | Gateway first (`serial: 1`), then all of `openclaw_nodes` in full — no gateway subtraction, since the gateway is deliberately a node too. `openclaw_optional` hosts get the same role in a trailing `ignore_unreachable` play. **Skips `pve-router` unless `-e confirm_pve_router=true`.** |
| `playbooks/update-openclaw.yml` | Fleet convergence: verify-before-mutate (compares `openclaw --version` against the `openclaw_version` pin, not a build hash — there's no build any more), gateway first, nodes serialized with a per-host health gate, skipping any host already converged. Phase 4 repeats phase 3 for `openclaw_optional`; both share `playbooks/tasks/converge-openclaw-node.yml`. **Not gated on `confirm_pve_router`** — this is the weekly-timer path, and `pve-router`'s automatic weekly convergence is a deliberate, already-made decision (2026-08-04), not an accidental sweep. See `homelab-vault` `TODO.md` for the planned ntfy-notification-with-approval-button replacement. |
| `playbooks/validate-openclaw.yml` | Version pin fleet-wide, gateway `/health`, both gateway-host services active, `openclaw nodes status`/`openclaw doctor` clean, now including `pve-router` like any other node. `openclaw_optional` hosts are asserted when up and reported when off. Read-only — not gated. |
| `playbooks/approve-openclaw-nodes.yml` | Explicit-invocation-only: auto-approves pending node pairing requests whose display name matches an inventory host; dry-run unless `-e openclaw_approve_confirm=true`. |
| `playbooks/decommission-openclaw-node.yml` | Tears down a single node (`-e target_host=<host>`), parameterised, no group target. Refuses the gateway host outright — its `/opt/openclaw` is the source-tree fallback, not a node install. **Refuses `pve-router` unless `-e confirm_pve_router=true`.** |
| `playbooks/openclaw-automation.yml` | Installs the weekly `openclaw-fleet-update` timer on the control node and retires the legacy self-updaters (cockpit's `openclaw-sync` units, the gateway's archived `openclaw-update` files). Installs automation only — it changes no OpenClaw install itself. |
| `playbooks/show-openclaw-version.yml` | Prints the resolved `openclaw_version`. |
| `playbooks/users/*.yml` | Per-account provisioning: `ansible-user.yml`, `claude-user.yml` (see `docs/claude-access.md`), `lfoss-user.yml`, `disable-requiretty.yml`. `hosts: all`, so these reach `pve-router` too — `ansible-user.yml`, `lfoss-user.yml`, and `disable-requiretty.yml` skip it unless `-e confirm_pve_router=true` (`claude-user.yml` defaults its target to `cockpit.home.lan` only, so it doesn't need the gate). |
| `playbooks/bootstrap/install-acl.yml` | ACL package bootstrap. `hosts: all`; skips `pve-router` unless `-e confirm_pve_router=true`. |
| `playbooks/bootstrap/bootstrap-vm-guest-agent.yml` | Brings a Proxmox guest that has **no sshd at all** to the point where normal SSH-based Ansible works, by running against the *hypervisor* and pushing a rendered script in through the QEMU guest agent (`-e bootstrap_vmid=<id>`). Also sets `onboot 1`. Refuses non-Debian-family guests. |
| `playbooks/bootstrap/nodesource-repo.yml` | Configures the NodeSource 22.x apt repo and asserts the `nodejs` candidate clears `openclaw_node_min_version`. Idempotent fleet-wide; required on any new host before `deploy-openclaw.yml`. Skips `pve-router` unless `-e confirm_pve_router=true`. |

The `nodes status --json` and `doctor --lint --json` schemas used by
`validate-openclaw.yml` are captured from live `2026.7.1-2` output (2026-08-01) and
documented in that file's header — they were previously inferred from prose, which is
exactly what made the first real run fail. `approve-openclaw-nodes.yml` was likewise
rewritten twice against real output.

## Fleet convergence automation

`openclaw-fleet-update.timer` on cockpit runs weekly as the `ansible` user:
`git pull --ff-only`, then `update-openclaw.yml`, then `validate-openclaw.yml`, and
records `/var/lib/openclaw-fleet-update/last-success` only if all of them exit 0. It
reads the version pin and never writes it — see
[`docs/execution-model.md`](docs/execution-model.md) for why that ordering is the whole
point of the rewrite.

```bash
systemctl list-timers openclaw-fleet-update.timer
systemctl start openclaw-fleet-update.service     # run it now, out of schedule
journalctl -u openclaw-fleet-update.service -n 200
cat /var/lib/openclaw-fleet-update/last-success
cat /var/lib/openclaw-fleet-update/last-failure    # absent while the last run was green
```

### Outcome notification

The timer used to announce a failure to nobody. On **2026-08-02 03:46** the first
real scheduled run died in `git pull` (root-owned objects under `/opt/ansible/.git`
that the `ansible` user could not write), the fleet was neither converged nor
validated that week, and the only evidence was a journal entry plus a `last-success`
file that quietly stopped advancing — by the time it was found, systemd had lost even
the failed state. That is the same class of self-masking failure the old
`openclaw-sync.sh` had.

`openclaw-fleet-update.service` now carries both hooks, pointing at one instantiated
unit whose instance name is the outcome:

```ini
OnFailure=openclaw-fleet-update-notify@failed.service
OnSuccess=openclaw-fleet-update-notify@ok.service
```

`openclaw-fleet-update-notify` (root, so it can read the failing unit's journal) then:

1. **Always** writes `/var/lib/openclaw-fleet-update/last-failure` on a failure —
   timestamp, unit result, exit status, checkout commit and the last 40 journal lines.
   The durable, greppable counterpart to `last-success`: if that has stopped advancing,
   this says why, without needing journal access.
2. Pushes to a **Zabbix trapper** item — `1` on failure, `0` on success, so a trigger
   raises *and clears itself* on the next good run.
3. POSTs to a **generic webhook** if `openclaw_control_notify_webhook` is set
   (ntfy/Gotify/Home Assistant/Discord). Empty by default.

Every channel is independent and best-effort, and the script never exits non-zero: a
notifier that failed loudly would mark its own unit failed while the real failure went
unmentioned, and there is nothing left to notify with about a broken notifier. Problems
go to the journal under `SyslogIdentifier=openclaw-fleet-update-notify`.

Email is deliberately not a channel: cockpit's postfix has no `relayhost` and
`myhostname=cockpit.localdomain`, so mail reaches a local mailbox nobody reads.

The Zabbix side is created by **`playbooks/zabbix-fleet-update-item.yml`** on host
`cockpit.home.lan` — a trapper item plus both triggers:

| | |
|---|---|
| Item | Type **Zabbix trapper**, key `openclaw.fleet.update`, type of information **Numeric (unsigned)** |
| Trigger — run failed | `last(/cockpit.home.lan/openclaw.fleet.update)=1` |
| Trigger — runs stopped | `nodata(/cockpit.home.lan/openclaw.fleet.update,10d)=1` |

The second trigger is the one that would have caught 2026-08-02: a timer that stops
firing altogether sends nothing at all, so only a nodata check notices. 10d spans the
weekly schedule plus its randomized delay.

> **This was a manual TODO for months, and it cost exactly what it was predicted to.**
> The item was never created by hand, and there were *two* faults rather than one. The
> missing item is the obvious half — the server accepts each value and discards it,
> logging `processed: 0; failed: 1`. The other half is that this notifier had
> `/etc/zabbix/zabbix_agentd.conf` hardcoded, and cockpit runs **agent2**
> (`zabbix_agent2.conf`), so once that migration happened the file stopped existing,
> the script's `[ ! -r ]` guard fired, and `zabbix_sender` was never invoked at all.
> Net effect: the timer failed on **2026-08-16** and **2026-08-23** and nothing said a
> word — `last-success` still read 2026-08-09 when this was found on 2026-08-24. The
> config path is now a *list* tried in order
> (`openclaw_control_notify_zabbix_confs`), because the failure mode was the
> hardcoding, not the value. Both halves must be applied for the channel to work:
> `zabbix-fleet-update-item.yml` for the item, `openclaw-automation.yml` to re-render
> the script.

Test either path without waiting for Sunday:

```bash
systemctl start openclaw-fleet-update-notify@failed.service
journalctl -t openclaw-fleet-update-notify -n 20
```

A hand-started `@failed` is detected as a test and **does not touch
`last-failure`**. The notifier compares the outcome it was handed against the
unit's real state: started by hand, `openclaw-fleet-update.service` sits at
`result=success`/`exit_status=0`, because it never ran. Such a run is written
to `last-test` instead, carrying an extra `manual_test=yes` line, and the
journal says so explicitly.

That distinction exists because this command used to destroy evidence. Before
2026-08-25 the test wrote straight into `last-failure`, producing a file named
`last-failure` that said `result=success` — and overwriting the real record of
the last genuine failure. It happened for real: a test on 2026-08-24 wiped the
2026-08-23 record, which had to be rebuilt from the journal. A genuine failure
can never be mistaken for a test in the other direction, since `OnFailure=`
only fires when the unit actually failed.

The Zabbix value is still pushed on a test — exercising the trapper → item →
trigger chain is the point — so expect the `last run FAILED` trigger to fire.
It clears on the next successful run.

## Bumping the OpenClaw version

The version is pinned by a human commit, not derived at runtime:

1. Edit `openclaw_version` in `group_vars/openclaw.yml` (npm version string — note the
   GitHub release tag is `v`-prefixed, e.g. package `2026.7.1-2` ↔ tag `v2026.7.1`).
2. Commit and push.
3. Run `playbooks/update-openclaw.yml`, or just wait for the weekly
   `openclaw-fleet-update` timer to pick the commit up — `common`'s install task no-ops
   on any host already at that version.

## Adding or rebuilding a host

The install is npm-owned and stateless on disk (no release tree to reconcile), so onboarding
a node is:

1. **Reachability.** The host needs sshd, python3 and the `ansible` user with
   `keys/ansible.pub`. On a host that already has sshd, that is
   `playbooks/users/ansible-user.yml`. On one that does not — a fresh desktop install, say —
   use `playbooks/bootstrap/bootstrap-vm-guest-agent.yml -e bootstrap_vmid=<id>`, which
   goes in through the Proxmox guest agent instead of SSH.
2. **Node.js source.** `playbooks/bootstrap/nodesource-repo.yml --limit <host>`. Do not skip
   this: `common` raises Node.js with `apt name=nodejs state=latest` but deliberately does
   not configure the repo, and Debian 13's own candidate (20.19) is *below*
   `openclaw_node_min_version`, so `common` would appear to succeed on a host that cannot
   run the pinned CLI.
3. **Inventory.** Add it to the relevant topology group (`vms`, `k8s_workers`, …) so it
   lands in `openclaw_nodes`; add it to `openclaw_optional` as well if it is not expected
   to be powered on continuously.
4. **Deploy.** `playbooks/deploy-openclaw.yml --limit <host>`. `common` handles the Node.js
   floor, user/group, CLI-path collisions, and the npm install idempotently.
5. **Approve the pairing** once the node registers:
   `playbooks/approve-openclaw-nodes.yml -e openclaw_approve_confirm=true`.

The gateway additionally needs its `.openclaw` state directory restored from
`/var/backups/openclaw-state-*.tar.gz` if this is a disaster rebuild rather than a routine
reprovision.

## Vault

The Ansible Vault password lives at `/etc/ansible-vault-password` on cockpit
(`root:ansible`, mode `0640`) and is wired into `ansible.cfg` via `vault_password_file`, so
`--vault-password-file` no longer needs to be passed by hand. Holds `openclaw_gateway_token`
in `group_vars/openclaw.yml`, the real `gateway.auth.token` value — required on every remote
node for token-mode auth, not a placeholder.

Also holds `opnsense_api_key` / `opnsense_api_secret` in
`group_vars/network_appliances.yml`. These belong to a **dedicated `ansible-writer` API
user**, deliberately separate from the credential the vault repo's `scripts/sync-opnsense.py`
uses: one credential serving two callers could not be revoked or re-scoped independently,
and the OPNsense audit log could not tell them apart. Grant it only *System: Configuration:
Backups* and *Services: Unbound DNS*. Create with:

```bash
ansible-vault encrypt_string --name opnsense_api_key    '<key>'
ansible-vault encrypt_string --name opnsense_api_secret '<secret>'
```

Until they are filled in, the OPNsense plays fail their credentials assert with
instructions and write nothing. Note that reverting these out of git does **not** revoke the
key — delete it in the OPNsense UI as well.

## Claude Code access

See [`docs/claude-access.md`](docs/claude-access.md) for how the `claude` automation
identity is provisioned and scoped on cockpit.
