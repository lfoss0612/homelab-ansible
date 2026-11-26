# The update cycle

The order that worked on 2026-11-15 to 2026-11-18, with the tools built since. Read it top to bottom
before a cycle; run one step at a time; every step says what to check and what stays a human call.
Commands use the wrappers (`scripts/run-working-tree.sh` runs the working tree from cockpit, dry run
unless `--apply`). Nothing is pushed or applied without an explicit go-ahead from whoever owns the
change. History lives in the vault's incident notes; **this file is the procedure**: fix it when a
step turns out wrong (see "After the cycle").

Rules that hold throughout: one host or app at a time, dry run first, a restore point before anything
that cannot be undone, non-critical hosts before critical ones, and stop at the first surprise.

## 0. Look first

```bash
scripts/run-working-tree.sh playbooks/fleet-versions.yml          # what is out of date, per component
scripts/run-working-tree.sh playbooks/zabbix-audit.yml            # monitoring healthy before we change it
scripts/run-working-tree.sh playbooks/post-release-upgrade-check.yml   # known problems before we add new ones
(cd ../homelab-gitops && scripts/chart-outdated.py)               # Argo/Helm charts behind, by risk tier
```

Verify: the report is the plan. Anything red here that is not caused by this cycle is noted and
either fixed first or written down as pre-existing, so it is not blamed on the cycle later.
Human judgment: which of the offered updates to take this cycle; reading release notes for breaking
changes (OS releases, Rancher/RKE2, charts with a MAJOR jump, OpenClaw, Zabbix).

## 1. Restore points

```bash
scripts/run-working-tree.sh --apply playbooks/pre-change-snapshot.yml -e snapshot_targets=<hosts> -e snapshot_change=<name>
(cd ../homelab-gitops && scripts/backup-before-upgrade.sh --label <name> --namespaces <ns> --etcd-save --apply)
```

Snapshot method is per host (`pve_snapshot_method`): Proxmox snapshot, or vzdump to PBS where the disks
are passthrough (omv). Longhorn backups use unique per-volume names; etcd is snapshotted on the
control plane; Argo CD gets an export; databases get a logical dump. Verify: the snapshot or backup is
listed and Completed. Old `pre-*` snapshots are pruned later with `prune-snapshots.yml`.

## 2. OS patching and reboots (non-critical first)

```bash
scripts/run-working-tree.sh playbooks/os-update.yml                         # dry run, then --apply
scripts/run-working-tree.sh playbooks/fleet-reboot.yml                      # which hosts need a reboot, in order
scripts/run-working-tree.sh --apply playbooks/fleet-reboot.yml -e reboot_host=<host> -e reboot_go=true
```

`os-update.yml` never reboots and excludes pve-router, k8s-worker-2 and the control node by design
(see its header). `fleet-reboot.yml` does one host per run with the gate for its kind: Kubernetes (drain,
Longhorn detach, Ready, uncordon), Proxmox (quorum survives, boot pin versus newest kernel), PBS (no
running tasks), omv (no NFS clients), dkms built for the kernel that will boot. Order: guests, workers,
control plane, PBS, then the hypervisors, pve-router last.
Verify after each: kernel is the expected one, no new failed units, `post-release-upgrade-check.yml`.
`os-update.yml` and a single-host `fleet-reboot.yml` finish by queueing Zabbix "Execute now" for the `os.update.*` items on the hosts they touched, so the Patch / Update Status dashboard is current at once (never fails the run; `-e os_update_zabbix_refresh=false` / `-e reboot_zabbix_refresh=false` skip it). The three k8s nodes cannot be polled for the pending count (their agent is a pod without apt; a host timer pushes it hourly), so both playbooks also start `os-update-push.service` on them. Hand-run updates (for example k8s-worker-2) need `zabbix-execute-now.yml` and, on a k8s node, `systemctl start os-update-push.service`.
Before a kernel or CUDA update on k8s-worker-2 run `k8s-worker-2-cuda-update.yml`: it makes the CUDA apt repo
trusted for the release (refreshing NVIDIA's keyring after a release upgrade, verified before install), and
reports upgradable NVIDIA/CUDA packages and whether DKMS covers the kernel that will boot.
Human judgment: the window for anything that takes the network down (pve-router carries OPNsense,
Zabbix, cockpit and 3 of 5 corosync votes), and a pinned boot kernel that should be moved.

## 3. Release upgrades (only when a release is due)

```bash
scripts/run-working-tree.sh playbooks/release-upgrade.yml -e release_host=<host>            # pre-checks
scripts/run-working-tree.sh --apply playbooks/release-upgrade.yml -e release_host=<host> -e release_go=true
scripts/run-working-tree.sh playbooks/post-release-upgrade-check.yml -e check_hosts=<host> -e expect_codename=<new>
```

Kubernetes nodes: cordon and drain with `k8s-node-release-upgrade.yml` (one node, control plane last).
Pre-checks encode the 2026-11-15 lessons: restore point, nothing left to patch, AppArmor drop-in on RKE2
nodes, MongoDB paused for kernel 6.19 or newer. Afterwards re-enable third-party repos for the new
suite (Zabbix, NodeSource, NVIDIA/CUDA, Docker) and check NIC names, DKMS (NVIDIA on worker-2) and the
Zabbix agent. Human judgment: pausing a service that cannot run on the new kernel, and which host first.

## 4. Zabbix server and agents

Back up the database and `zabbix_server.conf` first; upgrade the server, then the agents
(`deploy-zabbix-agent.yml`, `upgrade-to-zabbix-agent2.yml`); then `zabbix-audit.yml` and, for a dashboard
you want fresh now, `zabbix-execute-now.yml`. Verify: audit PASS, agent versions match the server
major.minor, config cache below the warning level.
After ANY change to the Zabbix packages or a release upgrade of the Zabbix VM, run
`playbooks/zabbix-web-check.yml` (dry run, then `--apply`): the Apache config shipped by
`zabbix-apache-conf` can change what modules it needs (2026-11-15: PHP-FPM, so `proxy` and `proxy_fcgi`), and a
running apache keeps its OLD config in memory, so nothing looks wrong until the next restart (2026-11-22: the
VM restarted, apache failed, and the web UI and API were down for 45 minutes while the server kept collecting).

## 5. Argo CD / Helm applications, riskiest last

For each app, `chart-upgrade` (skill in homelab-gitops): `chart-diff.py`, backup, bump the version in
git, refresh the parent `platform-<ns>` app, sync, verify. Order follows the tiers in
`docs/app-upgrade-risks.md`: routine first, data and platform apps (Longhorn, Yugabyte, GPU operator,
Rancher) one at a time, Argo CD itself last. After a Longhorn chart bump:
`scripts/longhorn-engine-upgrade.sh` (one volume first). After GPU/driver/Ollama changes:
`scripts/gpu-check.sh`. Human judgment: release notes, pausing or dropping a service, accepting an outage.

## 6. OpenClaw

```bash
scripts/run-working-tree.sh playbooks/openclaw-bump-rehearsal.yml -e rehearsal_version=<new>   # against a COPY of the state
# bump openclaw_version (and Node floor if needed) in group_vars/openclaw.yml, commit
scripts/run-working-tree.sh playbooks/update-openclaw.yml                                       # dry run, then --apply
```

Gateway first (it snapshots the VM, migrates state, passes a health gate), then a canary node, then the
rest; pairing approvals and node names are fixed by the same run. The weekly timer only reports a newer
release (and a Node end-of-life warning); it never bumps. Never skip a release that changes the state
schema: set `openclaw_upgrade_path` to walk the hops. Human judgment: whether to accept data loss when
the rehearsal says a jump is refused, and when to merge the pin to `main` (that activates the timer).

## 7. Validate

`fleet-versions.yml` (everything current), `zabbix-audit.yml` (monitoring healthy),
`post-release-upgrade-check.yml` (no new failed units), `validate-openclaw.yml`, Argo apps Synced and
Healthy (`kubectl get applications -n argocd`), `gpu-check.sh`. Compare with step 0: the only
differences should be the intended ones.

## 8. Record

For each host or component changed:

```bash
python3 ../homelab-vault/scripts/record-change.py --host <name> --text "<what changed, version, what is left>" \
    --incident <YYYY-MM-DD-slug> --heading "<short heading>" --apply
```

New incident note: the vault's `incident-note` skill. Topology or IP changes: the vault's
`INFRASTRUCTURE.md`. Then, with the owner's approval, push both repos.

## After the cycle: keep the facts out of the chat

The session lost state more than once last time, and the same facts were re-discovered. So, before
closing the cycle:

1. Anything learned that changes a step (a new trap, a new gate, a command that did not work) goes
   into this file, the playbook header or the script it belongs to, not only into the incident note.
   The incident note is history; this file is the procedure.
2. Every temporary workaround (a hand-edited file, a skipped check, a pinned version) is either made
   permanent in Ansible or git, or listed as a follow-up in the vault `TODO.md` with its reason.
3. Leftovers from testing (snapshots such as `pre-test-*`, test Longhorn backups, scratch directories on
   hosts) are removed or listed, so they are not mistaken for real restore points.
4. Review which tools and skills were actually used; fix or drop the ones that were not.
