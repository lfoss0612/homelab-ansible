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

## Playbooks

| File | Purpose |
|---|---|
| `playbooks/deploy-openclaw.yml` | Gateway first (`serial: 1`), then nodes. |
| `playbooks/update-openclaw.yml` | Fleet convergence/rollout. Predates the npm-based roles above (still source-build-shaped) — treat as pending a rewrite to match `common`/`gateway`/`node` before relying on it. |
| `playbooks/validate-openclaw.yml` | Topology assertions (currently just "gateway not in nodes" — inverted now that the gateway is deliberately a node; also pending a rewrite). |
| `playbooks/show-openclaw-version.yml` | Prints the resolved `openclaw_version`. |
| `playbooks/users/*.yml` | Per-account provisioning: `ansible-user.yml`, `claude-user.yml` (see `docs/claude-access.md`), `lfoss-user.yml`, `disable-requiretty.yml`. |
| `playbooks/bootstrap/install-acl.yml` | ACL package bootstrap. |

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
