# homelab-ansible

Control-node repo for the homelab's Ansible-managed hosts. Lives at `/opt/ansible` on
`cockpit.home.lan`, the control node; this checkout is a clone relayed to GitHub from a
workstation, since cockpit has no push credentials.

## Topology

13 inventory hosts total (`inventory.ini`):

- **`proxmox_hosts`** — `pve`, `pve-ai`, `pve-router` (three hypervisors).
- **`vms`** — `omv`, `zabbix`, `cockpit`, `pbs`, `pdm`, `vscode`, `openclaw` (the gateway VM).
- **`k8s_master` / `k8s_workers`** (parent group `k8s`) — `k8s-master`, `k8s-worker`,
  `k8s-worker-2`.

### OpenClaw fleet

`openclaw_nodes` = `openclaw_proxmox` (`pve`, `pve-ai` only) + `vms` + `k8s` — **12 hosts**.
`openclaw.home.lan` (the gateway) is a deliberate member: it runs both
`openclaw-gateway.service` and `openclaw-node.service`, managing its own VM as well as
brokering the rest of the fleet.

**`pve-router` is intentionally excluded** from `openclaw_nodes`. It runs a live,
independently-managed OpenClaw node (`openclaw-node.service`, registered with the gateway)
that this repo does not touch — decommissioning it is a separate, unscheduled task. Omission
from the group is what protects it; no play in this repo should ever target it by name.

Roles live in `collections/ansible_collections/openclaw/node/roles/`:

- **`common`** — shared install surface: Node.js floor (`openclaw_node_min_version`,
  guarded on installed version, not repo rewrite), `openclaw` user/group, log/state dirs,
  CLI-path collision handling, and `npm install -g openclaw@{{ openclaw_version }}`.
- **`gateway`** — backs up `~openclaw/.openclaw`, installs `common`, templates
  `openclaw-gateway.service`, health-gates on `/health` returning `{"ok":true}`.
- **`node`** — installs `common`, templates `/etc/default/openclaw-node` (gateway token +
  `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS`) and `openclaw-node.service`.

The CLI is npm-installed fleet-wide; there is no more per-host source build or
`releases/current/shared` directory tree.

## Execution model

OpenClaw nodes are the **read plane** (observe, tail, debug); Ansible is the **write
plane** for hosts; Argo CD is the write plane for anything in-cluster. Changes found by
debugging on a host are fixed by a playbook here, never by hand on the host. See
[`docs/execution-model.md`](docs/execution-model.md) — including the audit showing this is
not yet enforced, and the TODO to close it.

## Playbooks

| File | Purpose |
|---|---|
| `playbooks/deploy-openclaw.yml` | Gateway first (`serial: 1`), then all of `openclaw_nodes` in full — no gateway subtraction, since the gateway is deliberately a node too. |
| `playbooks/update-openclaw.yml` | Fleet convergence: verify-before-mutate (compares `openclaw --version` against the `openclaw_version` pin, not a build hash — there's no build any more), gateway first, nodes serialized with a per-host health gate, `end_host` wherever a host is already converged. |
| `playbooks/validate-openclaw.yml` | Version pin fleet-wide, gateway `/health`, both gateway-host services active, `openclaw nodes status`/`openclaw doctor` clean. `pve-router` is report-only — printed, never asserted against, never targeted. |
| `playbooks/approve-openclaw-nodes.yml` | Explicit-invocation-only: auto-approves pending node pairing requests whose display name matches an inventory host; dry-run unless `-e openclaw_approve_confirm=true`. |
| `playbooks/decommission-openclaw-node.yml` | Tears down a single node (`-e target_host=<host>`), parameterised, no group target. Refuses the gateway host outright — its `/opt/openclaw` is the source-tree fallback, not a node install. |
| `playbooks/show-openclaw-version.yml` | Prints the resolved `openclaw_version`. |
| `playbooks/users/*.yml` | Per-account provisioning: `ansible-user.yml`, `claude-user.yml` (see `docs/claude-access.md`), `lfoss-user.yml`, `disable-requiretty.yml`. |
| `playbooks/bootstrap/install-acl.yml` | ACL package bootstrap. |

`nodes status --json` / `devices list --json` field names used in `validate-openclaw.yml`
and `approve-openclaw-nodes.yml` (`status`, `paired`, `role`, `displayName`, `id`) are
inferred from prose in the fleet migration plan, not a captured sample of real output —
verify against a live run before trusting them unattended.

## Bumping the OpenClaw version

The version is pinned by a human commit, not derived at runtime:

1. Edit `openclaw_version` in `group_vars/openclaw.yml` (npm version string — note the
   GitHub release tag is `v`-prefixed, e.g. package `2026.7.1-2` ↔ tag `v2026.7.1`).
2. Commit and push.
3. Run `playbooks/deploy-openclaw.yml` (or the fleet-update automation on cockpit, once
   wired up) — `common`'s install task no-ops on any host already at that version.

## Rebuilding a host

The install is npm-owned and stateless on disk (no release tree to reconcile), so
rebuilding a node is: ensure the host is in `openclaw_nodes`, then run
`playbooks/deploy-openclaw.yml --limit <host>`. `common` handles the Node.js floor, user/
group, CLI-path collisions, and the npm install idempotently. The gateway additionally
needs its `.openclaw` state directory restored from `/var/backups/openclaw-state-*.tar.gz`
if this is a disaster rebuild rather than a routine reprovision.

## Vault

The Ansible Vault password lives at `/etc/ansible-vault-password` on cockpit
(`root:ansible`, mode `0640`) and is wired into `ansible.cfg` via `vault_password_file`, so
`--vault-password-file` no longer needs to be passed by hand. Holds `openclaw_gateway_token`
in `group_vars/openclaw.yml`, the real `gateway.auth.token` value — required on every remote
node for token-mode auth, not a placeholder.

## Claude Code access

See [`docs/claude-access.md`](docs/claude-access.md) for how the `claude` automation
identity is provisioned and scoped on cockpit.
