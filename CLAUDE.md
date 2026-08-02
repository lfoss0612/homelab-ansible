# Claude Code working context

Control-node repo for the homelab's Ansible-managed hosts (14 in `inventory.ini`), living
at `/opt/ansible` on `cockpit.home.lan`. Full detail is in **[README.md](README.md)**
(topology, roles, playbook table, version pinning, vault) — read it before deep work,
don't duplicate it here.

## The one rule that governs everything else

**OpenClaw nodes read; Ansible writes; Argo CD writes the cluster.** Anything found by
debugging on a host gets fixed by a playbook in this repo, never by hand on the host —
that is what makes the change reviewable and survivable across a rebuild. See
**[docs/execution-model.md](docs/execution-model.md)** for the reasoning, the current
enforcement gap, and the TODO to close it.

Corollary: **never grant the `openclaw` user sudo** to make a debugging task easier.

## Access path

A dedicated `claude` user exists on **cockpit only** (`10.0.5.10`, ssh alias `cockpit`),
with no `sudo`/`wheel` membership. It escalates via `sudo -u ansible` to exactly three
binaries — `/usr/bin/ansible`, `ansible-playbook`, `ansible-inventory` — and nothing else.
Full runbook in [docs/claude-access.md](docs/claude-access.md).

```bash
ssh cockpit 'cd /opt/ansible && sudo -n -H -u ansible /usr/bin/ansible-playbook playbooks/<play>.yml --check --diff'
```

- **Always `cd /opt/ansible` first.** Without it `ansible.cfg` is never discovered and
  Ansible silently uses the wrong inventory and collections path. It does not error.
- **Dry-run first.** `--check --diff` before any real apply.
- cockpit has no push credentials. To sync its checkout:
  `sudo -u ansible ansible localhost -m git -a 'repo=... dest=/opt/ansible version=main'`
  (a bare `git pull` as `claude` fails on `.git/FETCH_HEAD`).

## Gotchas that have already cost time

- **`ansible.cfg`'s key is `collections_path` (singular).** ansible-core 2.19.4 silently
  ignores `collections_paths` with no warning, and falls back to a stale galaxy copy in
  `~ansible/.ansible/collections`. **Verify with `ansible --version` after any
  `ansible.cfg` change** — the "ansible collection location" line is the only proof.
- **The gateway's npm global prefix is `/usr/local`; every other node's is `/usr`.** Never
  hardcode `/usr/bin/openclaw` — resolve it via `openclaw_npm_prefix.stdout`, as the
  `common` role does.
- **Approving a pending node is `openclaw nodes approve <id>`**, not `devices approve` —
  different tables (`nodes status --json` vs `devices list --json`).
- **`pve-router` is deliberately excluded** from `openclaw_nodes`. It runs an
  independently-managed node this repo must not touch. Omission from the group is the only
  thing protecting it — no play should ever target it by name.
- **`haos` is not in the inventory at all, on purpose.** It is Home Assistant OS — immutable,
  no apt, read-only `/usr`, no persistent `useradd`, no sshd — so the openclaw roles cannot
  run on it and adding it would only break every `hosts: all` play. Don't "fix" its absence.
- **`openclaw_optional` hosts (currently `desktop`) are normal nodes that may be powered
  off.** Strict plays use `openclaw_nodes:!openclaw_optional`; a second play repeats the
  work with `ignore_unreachable: true`. Any new play over the fleet must keep that split, or
  the weekly convergence timer goes red whenever the desktop is off.
- **`common` does not configure the NodeSource repo**, and Debian 13's own `nodejs`
  candidate (20.19) is below `openclaw_node_min_version`. A new host needs
  `playbooks/bootstrap/nodesource-repo.yml` before `deploy-openclaw.yml`, or the Node.js
  floor task silently installs something too old.
- **The whole fleet is on `2026.7.1-2`** as of 2026-08-01, npm layout everywhere. A host
  still holding a legacy `~openclaw/.openclaw/memory/main.sqlite` fails its startup
  migration when it crosses 2026.5.x — move the file aside, don't delete it. None of the
  12 had one, but a rebuilt-from-backup host could.
- **`/opt/ansible` is a group-shared checkout** (`core.sharedRepository=group`) because
  the weekly timer pulls it as the `ansible` user. Never run a playbook there as root —
  it leaves root-owned files in `.git` and `/home/ansible/.ansible/tmp` that break every
  later run as `ansible`. `openclaw.node.control` repairs this, but don't recreate it.
  This is not theoretical: it killed the 2026-08-02 scheduled run at `git pull`.
- **`command` tasks always report "skipping" under `--check`.** The message is
  `Command would have run if not in check mode` — that is the module having no check
  mode, *not* the `when` evaluating false. Read the `-v` output before concluding a
  guarded repair task didn't fire.
- **The fleet timer notifies via `OnFailure=`/`OnSuccess=`** into
  `openclaw-fleet-update-notify@.service` (Zabbix trapper + optional webhook +
  a `last-failure` file). The Zabbix trapper item must exist server-side or values are
  silently discarded — see README. Anything reading `/opt/ansible` as root needs
  `git -c safe.directory=`, or it gets dubious-ownership errors.
