#!/usr/bin/env bash
# Rehearse an OpenClaw upgrade on ONE host, against a COPY of its state. Run as root (the
# playbooks/openclaw-bump-rehearsal.yml play does that); the real install and the real state
# directory are only read. Everything it writes lives in one scratch directory that is removed
# on exit unless KEEP=1.
#
# Usage: openclaw-rehearsal-host.sh <target-version> [state-tarball]
#   target-version   npm version to try, e.g. 2026.11.5
#   state-tarball    optional .tar.gz of an older ~/.openclaw (the gateway role keeps these in
#                    /var/backups/openclaw-state-*.tar.gz); used instead of the live state. This is
#                    how a known-bad case is replayed.
# Environment: OPENCLAW_USER (default openclaw), DOCTOR_TIMEOUT (default 300), KEEP=1.
#
# Output is a block of KEY=value lines (grep-friendly) followed by the doctor log, so the
# playbook and a human read the same thing. Exit code: 0 the rehearsal ran (read RESULT=),
# 2 it could not run (bad input, install failed).
set -u

ver="${1:-}"
tarball="${2:-}"
user="${OPENCLAW_USER:-openclaw}"
timeout_s="${DOCTOR_TIMEOUT:-300}"

[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || { echo "RESULT=ERROR bad version '$ver'"; exit 2; }
home="$(getent passwd "$user" | cut -d: -f6)"
[[ -n "$home" && -d "$home" ]] || { echo "RESULT=ERROR no home for $user"; exit 2; }

scratch="$(mktemp -d /var/tmp/openclaw-rehearsal.XXXXXX)"
chown "$user":"$(id -gn "$user")" "$scratch"
chmod 700 "$scratch"
cleanup() { [[ "${KEEP:-0}" == 1 ]] && echo "KEPT=$scratch" || rm -rf "$scratch"; }
trap cleanup EXIT

as_user() { runuser -u "$user" -- env "HOME=$scratch/home" "PATH=$PATH" "$@"; }

real="$home/.openclaw"
before="$(stat -c '%Y %s' "$real/openclaw.json" 2>/dev/null || echo none)"
echo "HOST=$(hostname -f)"
echo "TARGET=$ver"
echo "CURRENT=$(openclaw --version 2>/dev/null | head -1)"
echo "NODE=$(node --version 2>/dev/null)"
echo "NODE_REQUIRES=$(npm view "openclaw@$ver" engines.node 2>/dev/null | tr -d '\n')"

mkdir -p "$scratch/home"
chown "$user":"$(id -gn "$user")" "$scratch/home"

# 1. Copy of the state. Big, rebuildable directories are left out; the rest is what doctor migrates.
if [[ -n "$tarball" ]]; then
  [[ -f "$tarball" ]] || { echo "RESULT=ERROR no such tarball $tarball"; exit 2; }
  tar -xzf "$tarball" -C "$scratch/home" || { echo "RESULT=ERROR cannot extract $tarball"; exit 2; }
  echo "STATE_SOURCE=$tarball"
else
  [[ -d "$real" ]] || { echo "RESULT=ERROR no state dir $real"; exit 2; }
  mkdir -p "$scratch/home/.openclaw"
  tar -C "$real" --exclude=./logs --exclude=./media --exclude=./cache --exclude=./backups \
      --exclude=./completions --exclude=./tmp -cf - . | tar -C "$scratch/home/.openclaw" -xf -
  echo "STATE_SOURCE=$real (live, copied)"
fi
chown -R "$user":"$(id -gn "$user")" "$scratch/home"

# The live gateway holds a lease row in the state database, and a copy of it makes doctor say
# "state database is busy" and do nothing. On the COPY only: take a consistent snapshot of the
# live database (the files are in use, a plain file copy can be torn), then drop the lease rows.
if command -v sqlite3 >/dev/null 2>&1; then
  live_db="$real/state/openclaw.sqlite"
  copy_db="$scratch/home/.openclaw/state/openclaw.sqlite"
  if [[ -z "$tarball" && -f "$live_db" ]]; then
    rm -f "$copy_db" "$copy_db-wal" "$copy_db-shm"
    as_user sqlite3 -readonly "$live_db" ".backup '$copy_db'" || echo "NOTE=could not snapshot $live_db"
  fi
  while IFS= read -r db; do
    for t in state_leases agent_database_leases; do
      out="$(as_user sqlite3 "$db" "DELETE FROM $t; SELECT changes();" 2>&1)" \
        && echo "LEASES_CLEARED=$t:$out:${db#"$scratch"/home/.openclaw/}" \
        || { [[ "$out" == *"no such table"* ]] || echo "NOTE=lease clear failed on $db: $out"; }
    done
  done < <(find "$scratch/home/.openclaw" -name '*.sqlite' -type f)
else
  echo "NOTE=sqlite3 not installed; lease rows in a copied state database are not cleared"
fi
echo "STATE_SIZE=$(du -sh "$scratch/home/.openclaw" | cut -f1)"
( cd "$scratch/home/.openclaw" && find . -type f | sort ) > "$scratch/files.before"

# 2. The target version in a private prefix. --engine-strict refuses a Node that is too old,
#    exactly as the real install does.
mkdir -p "$scratch/prefix"
chown "$user":"$(id -gn "$user")" "$scratch/prefix"
if ! as_user npm install --prefix "$scratch/prefix" --engine-strict --no-audit --no-fund --loglevel=error \
      "openclaw@$ver" > "$scratch/npm.log" 2>&1; then
  echo "RESULT=ERROR npm install of openclaw@$ver failed"
  tail -n 15 "$scratch/npm.log"
  exit 2
fi
bin="$scratch/prefix/node_modules/.bin/openclaw"
echo "INSTALLED=$(as_user "$bin" --version 2>/dev/null | head -1)"

# 3. Doctor against the copy. HOME and OPENCLAW_STATE_DIR both point into the scratch directory so
#    nothing outside it is written.
as_user env "OPENCLAW_STATE_DIR=$scratch/home/.openclaw" \
  timeout "$timeout_s" "$bin" doctor --fix --non-interactive > "$scratch/doctor.log" 2>&1
rc=$?
echo "DOCTOR_RC=$rc"

( cd "$scratch/home/.openclaw" && find . -type f | sort ) > "$scratch/files.after"
echo "FILES_ADDED=$(comm -13 "$scratch/files.before" "$scratch/files.after" | wc -l)"
echo "FILES_REMOVED=$(comm -23 "$scratch/files.before" "$scratch/files.after" | wc -l)"
comm -13 "$scratch/files.before" "$scratch/files.after" | head -n 15 | sed 's/^/ADDED /'
comm -23 "$scratch/files.before" "$scratch/files.after" | head -n 15 | sed 's/^/REMOVED /'

# 4. Things doctor says that mean a real upgrade would be refused or lose data. Doctor exits 1 even
#    on success (see roles/gateway), so the text is the signal, not the exit code.
refusals="$(grep -i -E 'refus|unreleased|cannot (read|migrate|open|repair)|not supported|incompatible|unsupported|downgrade|permission denied|EACCES|EPERM|skipped .*migration|requires migration|failing check|failed to|error:' "$scratch/doctor.log" | grep -v -i -E 'DeprecationWarning|legacy=none' | head -n 30)"
hard="$(grep -i -E 'refused to continue|cannot repair|unreleased|requires migration' "$scratch/doctor.log" | head -n 1)"
if grep -q -i -E 'could not enter maintenance|state database is busy' "$scratch/doctor.log"; then
  result="INCONCLUSIVE (doctor could not start on the copy: state lock; nothing was tested)"
elif [[ "$rc" -ge 2 ]]; then
  result="FAIL (doctor killed or crashed, rc $rc)"
elif [[ -n "$hard" ]]; then
  result="FAIL (doctor refused to migrate this state; a real bump would stop here, see below)"
elif [[ -n "$refusals" ]]; then
  result="REVIEW (doctor mentions refusals or legacy state; read the lines below)"
else
  result="PASS"
fi
echo "REFUSAL_LINES=$(printf '%s' "$refusals" | grep -c .)"
echo "RESULT=$result"
if [[ -n "$refusals" ]]; then echo "--- lines that matched ---"; echo "$refusals"; fi
echo "--- doctor log, last 40 lines ---"
tail -n 40 "$scratch/doctor.log"

# 5. What the release notes say about state, from the CHANGELOG shipped inside the package.
cl="$scratch/prefix/node_modules/openclaw/CHANGELOG.md"
if [[ -f "$cl" ]]; then
  sec="$(awk -v v="$ver" '$0 ~ "^## " && index($0, v) {f=1; next} f && /^## /{exit} f' "$cl")"
  echo "CHANGELOG_LINES=$(printf '%s' "$sec" | grep -c .)"
  printf '%s\n' "$sec" | grep -i -E 'state|migrat|retired|breaking|remov|deprecat|schema|node' | cut -c1-240 | head -n 25 | sed 's/^/NOTES /'
else
  echo "NOTE=no CHANGELOG.md in the package"
fi

# 6. The real state must be exactly as it was.
after="$(stat -c '%Y %s' "$real/openclaw.json" 2>/dev/null || echo none)"
if [[ "$before" != "$after" ]]; then
  echo "WARNING=the real openclaw.json changed during the rehearsal ($before -> $after)"
else
  echo "REAL_STATE_UNTOUCHED=yes"
fi
exit 0
