#!/bin/bash
#
# Copy this node's RKE2 etcd snapshots and server credential material to the
# k8s_backups NFS export on pbs, so a "critical failure" of this host does not
# also take out the only copy of its own disaster-recovery data.
#
# RKE2's automatic etcd snapshots (every 12h, retention 5) live under
# /var/lib/rancher/rke2/server/db/snapshots on THIS SAME disk. On a single
# control-plane cluster that is the actual gap: the backup and the thing it
# protects against share one point of failure. This script is the off-node
# copy step; it does not touch RKE2's own snapshot schedule or retention.
#
# Also copies /var/lib/rancher/rke2/server/ EXCEPT db/ (the live etcd data,
# already covered by the snapshot mechanism, and not a valid point-in-time
# copy taken live). That directory carries the cluster CA private keys, the
# Secret-encryption keys (cred/encryption-*.json - without these a restored
# snapshot's Secrets are permanently unreadable), and the join token. An etcd
# snapshot alone cannot rebuild a cluster without this. See
# playbooks/pbs-export-k8s-datastore.yml for the fuller reasoning.
#
# ---------------------------------------------------------------------------
# The NFS mount is on-demand, not persistent (no fstab entry).
#
# This runs on a Kubernetes control-plane node. A permanent mount that hangs
# because pbs is briefly unreachable is a worse outcome than a missed backup
# cycle - it risks the node itself, not just this job. `soft` + a bounded
# timeout means an unreachable server fails this script within seconds
# instead of hanging, and the LOCAL etcd snapshot this script is copying is
# entirely unaffected either way: RKE2's own snapshot job runs independently
# and has already succeeded or failed before this script ever runs.
# ---------------------------------------------------------------------------
#
# A failed copy here is NOT masked as success. Unlike a monitoring probe
# reporting "the thing I check is unhealthy" as a normal outcome, a failed
# BACKUP copy is itself the bad outcome - so this exits non-zero on any real
# failure, and a red systemd unit is the correct, intended signal.

set -uo pipefail

NFS_SERVER="${NFS_SERVER:-10.0.5.5}"
NFS_EXPORT="${NFS_EXPORT:-/mnt/datastore/k8s_backups}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/k8s-etcd-backup-nfs}"
RKE2_SERVER_DIR="${RKE2_SERVER_DIR:-/var/lib/rancher/rke2/server}"
HOST_TAG="${HOST_TAG:-$(hostname -s)}"

log() { printf '%s\n' "$*" >&2; }

cleanup() {
	if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
		umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null
	fi
}
trap cleanup EXIT

if [ ! -d "$RKE2_SERVER_DIR/db/snapshots" ]; then
	log "ERROR: $RKE2_SERVER_DIR/db/snapshots not found -- is this an RKE2 server node?"
	exit 1
fi

mkdir -p "$MOUNT_POINT"

# soft + a bounded timeout: see header. retry=1 avoids the default multi-minute
# retry loop on a server that is simply down right now.
if ! mount -t nfs4 -o soft,timeo=100,retry=1 "$NFS_SERVER:$NFS_EXPORT" "$MOUNT_POINT"; then
	log "ERROR: could not mount $NFS_SERVER:$NFS_EXPORT -- pbs unreachable or export missing."
	log "       Local etcd snapshots are unaffected; only the off-node copy was skipped."
	exit 1
fi

dest_snapshots="$MOUNT_POINT/etcd-snapshots/$HOST_TAG"
dest_serverdir="$MOUNT_POINT/server-config/$HOST_TAG"
mkdir -p "$dest_snapshots" "$dest_serverdir"

# -a preserves ownership and permissions, which matters here specifically:
# the private keys under tls*/ and cred/ are 0600 and must stay that way.
# --numeric-ids avoids remapping through name lookups across hosts.
# No --delete: this is a growing off-node history, not a mirror. Capacity is
# trivial (checked 2026-08-25: ~1.1 MB for server-config, tens of MB per
# snapshot) against 6+ TB free, so retaining more history than RKE2's own
# on-node retention of 5 is a feature, not something to prune here.
rc=0

log "Syncing etcd snapshots..."
rsync -a --numeric-ids "$RKE2_SERVER_DIR/db/snapshots/" "$dest_snapshots/" || rc=1

log "Syncing server credential material (excluding db/)..."
rsync -a --numeric-ids \
	--exclude=db \
	"$RKE2_SERVER_DIR/" "$dest_serverdir/" || rc=1

if [ "$rc" -eq 0 ]; then
	log "OK: etcd snapshots and server config synced to $NFS_SERVER:$NFS_EXPORT"
else
	log "ERROR: rsync reported a failure -- see the messages above."
fi

exit "$rc"
