#!/usr/bin/env bash
# Run every repo lint. Exit 1 if any fails. Used by the pre-commit hook, safe to run by hand:
#   scripts/run-lints.sh
# Lints read the working tree, not only what is staged.
cd "$(dirname "$0")/.." || exit 2
rc=0
for l in scripts/lint-check-mode.py scripts/lint-playbook-names.py scripts/lint-variable-scope.py; do
  out=$(python3 "$l" 2>&1) || { echo "FAIL $l"; echo "$out" | tail -25; rc=1; }
done
[ $rc -eq 0 ] && echo "lints: all clean"
exit $rc
