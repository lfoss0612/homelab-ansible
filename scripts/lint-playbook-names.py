#!/usr/bin/env python3
"""
Lint for the single-run playbook naming rule.

A single-run playbook is a migration, a cleanup or a one-time repair: it does a job once and
re-running it is pointless. It is named `once-<what>.yml` and carries a marker as its first
comment line:

    ---
    # Single-run: pending - <what it will do>

Once it has been applied and recorded in the vault it is deleted (git history keeps it).
Rules (standard library only):

  N1  A file named once-*.yml has no `# Single-run:` marker in its first 5 lines.
  N2  A file with a `# Single-run:` marker is not named once-*.yml.
  N3  The marker's status is not `pending` (a finished playbook is deleted, not marked).

A playbook that is meant to be re-run (standing automation, or a fix that applies again after
every release upgrade) is NOT single-run and keeps its descriptive name.

Usage:
    scripts/lint-playbook-names.py [paths...]     # default: playbooks/

Exit code 1 if any finding is reported.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MARKER = re.compile(r"^#\s*Single-run:\s*(\S+)", re.IGNORECASE)
STATUSES = {"pending"}


def check(path: Path) -> list[str]:
    head = path.read_text(errors="replace").splitlines()[:5]
    status = None
    for line in head:
        match = MARKER.match(line)
        if match:
            status = match.group(1).lower().rstrip(":,")
            break
    once_named = path.name.startswith("once-")
    problems = []
    if once_named and status is None:
        problems.append("N1 named once-* but has no '# Single-run: pending' line in its first 5 lines")
    if status is not None and not once_named:
        problems.append("N2 has a '# Single-run:' marker but is not named once-<what>.yml")
    if status is not None and status not in STATUSES:
        problems.append(f"N3 marker status '{status}' must be 'pending'; delete a finished playbook")
    return problems


def main(argv: list[str]) -> int:
    roots = [Path(a) for a in argv] or [REPO / "playbooks"]
    files = []
    for root in roots:
        files += sorted(root.rglob("*.yml")) if root.is_dir() else [root]
    findings = 0
    for path in files:
        for problem in check(path):
            findings += 1
            print(f"{path.relative_to(REPO) if path.is_absolute() and REPO in path.parents else path}: {problem}")
    print(f"{findings} finding(s) across {len(files)} files")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
