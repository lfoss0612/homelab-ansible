#!/usr/bin/env bash
# Run a playbook from the local WORKING TREE on the control node (cockpit), without
# committing or pushing first.
#
# It ships the working tree to a unique scratch directory on cockpit, points ansible.cfg
# at that directory, runs ansible-playbook there as the ansible user, and always removes
# the scratch copy afterwards (success, failure or Ctrl-C).
#
# Usage:
#   scripts/run-working-tree.sh [options] playbooks/<play>.yml [ansible-playbook args...]
#
# Options (must come first):
#   --apply        really run. Without it the script adds --check --diff.
#   --keep         leave the scratch copy on cockpit (printed on exit) for debugging.
#   -h | --help    show this help.
#
# Examples:
#   scripts/run-working-tree.sh playbooks/validate-openclaw.yml
#   scripts/run-working-tree.sh --apply playbooks/update-openclaw.yml --limit openclaw_nodes
#
# What is copied: every file git tracks, plus untracked files that .gitignore does not
# exclude. Ignored files (vault passwords, kubeconfigs, keys, .env) never leave this
# machine. The vault password and the SSH keys stay where they are on cockpit.
#
# Reaches cockpit only as claude@cockpit, as docs/claude-access.md requires. Because all
# the quoting lives in this file, callers never put an inline ssh command line through the
# access hook.

set -euo pipefail

CONTROL_HOST="${CONTROL_HOST:-claude@cockpit}"
REMOTE_BASE="/tmp"
REMOTE_REPO_PATH="/opt/ansible"
ANSIBLE_PLAYBOOK="/usr/bin/ansible-playbook"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

apply=0
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown option: $1 (options must come before the playbook)" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
playbook="$1"
if [ ! -f "$repo_root/$playbook" ]; then
  echo "playbook not found in the working tree: $playbook (give a path relative to the repo root)" >&2
  exit 2
fi

# A unique, unguessable directory so concurrent or leftover runs never collide.
run_id="ansible-run-$(date +%Y%m%d-%H%M%S)-$$"
remote_dir="$REMOTE_BASE/$run_id"

# Safety: the cleanup below runs rm -rf, so only ever operate inside our own prefix.
case "$remote_dir" in
  /tmp/ansible-run-[0-9]*) ;;
  *) echo "refusing odd scratch path: $remote_dir" >&2; exit 1 ;;
esac

cleaned=0
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$cleaned" -eq 0 ]; then
    cleaned=1
    if [ "$keep" -eq 1 ]; then
      echo "kept scratch copy on cockpit: $remote_dir" >&2
    else
      # The directory is owned by claude, but a playbook run as ansible can leave files
      # it owns behind; report that rather than hide it.
      if ! ssh "$CONTROL_HOST" "rm -rf '$remote_dir'" 2>/dev/null; then
        echo "WARNING: could not remove $remote_dir on cockpit; remove it by hand" >&2
      fi
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo ">> shipping working tree to cockpit:$remote_dir" >&2
(
  cd "$repo_root"
  # -c cached (tracked) + -o others (untracked); --exclude-standard honours .gitignore.
  # --deduplicate guards against a file listed twice. Deleted-but-tracked files are
  # filtered out below so tar does not fail on them.
  git ls-files -z -c -o --exclude-standard --deduplicate \
    | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -
) | ssh "$CONTROL_HOST" "
  set -e
  mkdir -m 755 '$remote_dir'
  tar -xf - -C '$remote_dir'
  # Re-point every absolute /opt/ansible reference at the scratch copy.
  sed -i 's#$REMOTE_REPO_PATH#$remote_dir#g' '$remote_dir/ansible.cfg'
  # The ansible user must be able to read the copy.
  chmod -R a+rX '$remote_dir'
"

args=("$@")
if [ "$apply" -eq 0 ]; then
  args+=(--check --diff)
  echo ">> dry run (--check --diff); pass --apply to make changes" >&2
else
  echo ">> APPLYING changes" >&2
fi

quoted=""
for a in "${args[@]}"; do
  quoted+=" $(printf '%q' "$a")"
done

echo ">> ansible-playbook$quoted" >&2
# -t gives colour and a live tty when run interactively; harmless otherwise.
tty_flag=()
if [ -t 1 ]; then tty_flag=(-t); fi
ssh "${tty_flag[@]}" "$CONTROL_HOST" \
  "cd '$remote_dir' && sudo -n -H -u ansible $ANSIBLE_PLAYBOOK$quoted"
