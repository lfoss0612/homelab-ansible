# RKE2 and Rancher upgrade checklist

Before any RKE2 or Rancher upgrade. Pairs with the `chart-upgrade` skill (Rancher is an Argo CD chart) and
`playbooks/rke2-node-upgrade.yml` (one node per run, drained, control plane first).
Everything here was learned on 2026-11-15 (Rancher 2.14.3 to 2.15.3, RKE2 v1.36.1 to v1.36.6).

## Read first (human)

1. Rancher release notes between the two versions, and the matching Rancher support matrix: which RKE2
   (Kubernetes) minors it supports, so Rancher goes first when the new RKE2 minor needs it.
2. Removed objects: Rancher 2.15 removed the `system-upgrade` ServiceAccount and anything that
   referenced it. Search the cluster for what used it before upgrading
   (`kubectl get clusterrolebindings,rolebindings -A | grep system-upgrade`).
3. Charts the new Rancher takes over (it took over `rancher-turtles` and the system-upgrade-controller
   charts in 2.15, causing a helm-operation pod flood). Decide per chart: let Rancher own it, or keep it
   out of Rancher; do not let both manage it.
4. RKE2 notes: the new Kubernetes minor's removed APIs, containerd and runc changes, any changed default
   (AppArmor and kernel interactions, see below).

## Check the cluster (read-only, scripted where possible)

```bash
kubectl get nodes -o wide                                     # all Ready, versions as expected
scripts/run-working-tree.sh playbooks/k8s-containerd-drift-check.yml     # AppArmor drop-in, templates, units
kubectl get volumes.longhorn.io -n longhorn-system            # none degraded or rebuilding
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
kubectl get nodes -o custom-columns=N:.metadata.name,P:.status.allocatable.pods,U:.status.capacity.pods
```

- **Per-node pod limit**: a Rancher chart takeover can launch dozens of `helm-operation` pods at once; the
  nodes hit the pod limit on 2026-11-15. Confirm headroom (allocatable pods minus running pods on the
  node) or raise `max-pods` first.
- **Backups**: etcd snapshot (`scripts/backup-before-upgrade.sh --etcd-save` in homelab-gitops), Longhorn
  backups of attached volumes, and for Rancher its own backup/export of the `cattle-system` objects.
- **SUC plan**: the system-upgrade-controller plan drains with a plain drain, which hangs on Longhorn's
  instance-manager PDB. Keep plans without a drain, or give them the selector
  `longhorn.io/component!=instance-manager`; the playbook labels each node `rke2-upgrade=disabled` while
  it works so the plan does not race it.
- **Control plane**: single etcd, so the API is down while `rke2-server` restarts. The control plane is
  masked for `rke2-agent`; use `rke2-server` there. Schedule that restart, do not do it casually.
- **GPU node**: after RKE2 or kernel changes run `scripts/gpu-check.sh` (homelab-gitops).

## Order

1. Backups, then Rancher (chart-upgrade skill) if its notes require it first. `rancher-webhook` follows Rancher and is no longer listed by `chart-outdated.py`: in the same change set `targetRevision` in homelab-gitops `argocd/cattle-system/rancher-webhook.yaml` to the webhook chart the new Rancher ships (check `helm list -n cattle-system` after the Rancher sync).
2. RKE2 on the control plane: `rke2-node-upgrade.yml -e rke2_node=k8s-master.home.lan -e rke2_target=... -e rke2_allow_control_plane=true`.
3. RKE2 on each worker, one at a time. A worker whose Longhorn volume has only one in-sync replica leaves
   that volume unavailable until it is back; the playbook's health gate refuses while a volume is degraded.
4. `post-release-upgrade-check.yml`, `zabbix-audit.yml`, Argo apps Synced and Healthy.
