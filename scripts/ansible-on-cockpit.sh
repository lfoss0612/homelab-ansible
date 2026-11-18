#!/usr/bin/env bash
# Run ad-hoc Ansible commands and read-only probes through the control node (cockpit) with
# no inline ssh quoting. All quoting lives here, so the access hook never sees a complex
# command line. For playbooks from your working tree use scripts/run-working-tree.sh.
#
# Usage:
#   scripts/ansible-on-cockpit.sh probe list
#   scripts/ansible-on-cockpit.sh probe <name> [pattern] [extra ansible args]
#   scripts/ansible-on-cockpit.sh adhoc <pattern> -m <module> [-a <args>] [more ansible args]
#   scripts/ansible-on-cockpit.sh inventory [ansible-inventory args]
#   scripts/ansible-on-cockpit.sh playbook [--apply] playbooks/<play>.yml [args]
#
# probe     runs scripts/probes/<name>.sh on the matching hosts via the script module and
#           prints one line per host. Probes are read-only; add new ones as files, never as
#           inline shell. Default pattern is all:!api_managed, because api_managed hosts
#           (opnsense, litellm) use a local connection and would silently run on cockpit.
# adhoc     runs /usr/bin/ansible. Modules that only read (ping, setup, command, shell,
#           script, raw, slurp, stat, find, getent, package_facts, service_facts,
#           systemd_service with no state) run freely; anything else needs --apply before
#           the module. Under --check, command-like modules are skipped; prefer a probe.
# inventory runs /usr/bin/ansible-inventory.
# playbook  runs a playbook from the COMMITTED checkout on cockpit (/opt/ansible), dry run
#           unless --apply. To run uncommitted changes use run-working-tree.sh instead.
#
# Notes:
#   * In ad-hoc arguments avoid Jinja ({{ }}); it is expanded by Ansible and by the remote
#     shell. Put the logic in a probe file and use it with the script module.
#   * Probe output is reduced to one line per host; a failed host prints its error and the
#     command exits 1. Hosts with sudo or login noise still show only the probe's own line.

set -euo pipefail

CONTROL_HOST="${CONTROL_HOST:-claude@cockpit}"
REPO="/opt/ansible"
SUDO="sudo -n -H -u ansible"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probes_dir="$here/probes"

die() { echo "$*" >&2; exit 2; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

quote_args() {
  local out="" a
  for a in "$@"; do out+=" $(printf '%q' "$a")"; done
  printf '%s' "$out"
}

remote() {
  # $1 = binary, rest = args
  local bin="$1"; shift
  ssh "$CONTROL_HOST" "cd $REPO && $SUDO $bin$(quote_args "$@")"
}

list_probes() {
  for f in "$probes_dir"/[!_]*.sh; do
    n="$(basename "$f" .sh)"
    d="$(sed -n '2s/^# *//p' "$f")"
    printf '  %-18s %s\n' "$n" "$d"
  done
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift

case "$cmd" in
  -h|--help|help) usage ;;

  inventory)
    remote /usr/bin/ansible-inventory "$@"
    ;;

  playbook)
    apply=0
    if [ "${1:-}" = "--apply" ]; then apply=1; shift; fi
    [ $# -ge 1 ] || die "playbook: give a playbook path"
    args=("$@")
    [ "$apply" -eq 1 ] || args+=(--check --diff)
    remote /usr/bin/ansible-playbook "${args[@]}"
    ;;

  adhoc)
    [ $# -ge 1 ] || die "adhoc: give a host pattern and -m <module>"
    apply=0
    args=()
    module=""
    prev=""
    for a in "$@"; do
      if [ "$a" = "--apply" ]; then apply=1; prev="$a"; continue; fi
      if [ "$prev" = "-m" ]; then module="$a"; fi
      args+=("$a"); prev="$a"
    done
    [ -n "$module" ] || die "adhoc: -m <module> is required"
    case "$module" in
      ping|setup|command|shell|script|raw|slurp|stat|find|getent|package_facts|service_facts) ;;
      *) [ "$apply" -eq 1 ] || die "adhoc: module '$module' can change state; re-run with --apply if intended" ;;
    esac
    remote /usr/bin/ansible "${args[@]}"
    ;;

  probe)
    name="${1:-}"
    [ -n "$name" ] || die "probe: give a name (try: probe list)"
    shift
    if [ "$name" = "list" ]; then list_probes; exit 0; fi
    file="$probes_dir/$name.sh"
    [ -f "$file" ] || { echo "no such probe: $name. Available:" >&2; list_probes >&2; exit 2; }
    pattern="${1:-all:!api_managed}"
    [ $# -gt 0 ] && shift
    # Ship the probe to a private temp file on cockpit, run it, remove it.
    remote_file="$(ssh "$CONTROL_HOST" 'f=$(mktemp /tmp/probe-XXXXXXXX.sh) && cat > "$f" && chmod 755 "$f" && echo "$f"' < "$file")"
    case "$remote_file" in /tmp/probe-*.sh) ;; *) die "unexpected probe path: $remote_file" ;; esac
    trap 'ssh "$CONTROL_HOST" "rm -f \"$remote_file\"" >/dev/null 2>&1 || true' EXIT
    # -o keeps one line per host; _format.py reduces it to "host  probe-output".
    remote /usr/bin/ansible "$pattern" -m script -a "$remote_file" -o "$@" 2>&1 \
      | python3 -I "$probes_dir/_format.py"
    ;;

  *) usage >&2; die "unknown command: $cmd" ;;
esac
