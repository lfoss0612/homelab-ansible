#!/usr/bin/env python3
"""
Lint for tasks that lie under `ansible-playbook --check`.

Under --check, `command`, `shell`, `raw` and `script` tasks are skipped, so a task that only
reads state leaves its registered variable empty and later assertions fail (or, worse, the
dry run shows the whole fleet changing). A task that only reads must say so:

    - command: ...
      register: probe
      changed_when: false
      check_mode: false

Rules (standard library only, so it runs without PyYAML):

  E1  command/shell/raw/script task with `changed_when: false` but no `check_mode:`.
      It is declared read-only, so it should run in check mode too.
  W1  command/shell/raw/script task that has `register:` but neither `check_mode:` nor
      `changed_when:`. If the registered value is used by later tasks it will be empty in
      a dry run; decide whether the task is a read-only probe or a real change.

A task can opt out with a `# lint-check-mode: ignore` comment inside it.

Usage:
    scripts/lint-check-mode.py [paths...]     # default: playbooks, collections, roles
    scripts/lint-check-mode.py --strict       # warnings also fail the run

Exit code 1 if any error (or, with --strict, any warning) is found.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_PATHS = ["playbooks", "collections/ansible_collections/openclaw", "roles"]
MODULES = r"(?:ansible\.builtin\.)?(?:command|shell|raw|script)"
TASK_START = re.compile(r"^(\s*)-\s+(?:name:|%s:|block:|ansible\.)" % MODULES)
MODULE_KEY = re.compile(r"^\s*(?:-\s+)?%s:" % MODULES)
IGNORE = "lint-check-mode: ignore"


def task_blocks(lines):
    """Yield (start_line_number, [lines]) for each list item that looks like a task."""
    starts = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)-\s+\S", line)
        if m:
            starts.append((i, len(m.group(1))))
    for idx, (i, indent) in enumerate(starts):
        end = len(lines)
        for j in range(i + 1, len(lines)):
            m = re.match(r"^(\s*)\S", lines[j])
            if m and lines[j].strip() and not lines[j].lstrip().startswith("#") and len(m.group(1)) <= indent:
                end = j
                break
        yield i + 1, lines[i:end], indent


def own_lines(block, indent):
    """Lines that belong to this task itself, not to a nested block's child tasks."""
    out = []
    for line in block:
        out.append(line)
    # Stop at a nested task list (block:/rescue:/always:) so child tasks are linted on their own.
    cut = len(out)
    for k, line in enumerate(out):
        if re.match(r"^\s*(block|rescue|always|tasks|pre_tasks|post_tasks|handlers):\s*$", line):
            cut = k
            break
    return out[:cut]


def lint_file(path):
    problems = []
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return problems
    for lineno, block, indent in task_blocks(lines):
        mine = own_lines(block, indent)
        text = "\n".join(mine)
        if IGNORE in text:
            continue
        if not any(MODULE_KEY.match(l) for l in mine):
            continue
        name = next((re.sub(r"^\s*-?\s*name:\s*", "", l).strip("\"' ") for l in mine if "name:" in l), "(unnamed)")
        has_check = re.search(r"^\s*check_mode:", text, re.M) is not None
        ro = re.search(r"^\s*changed_when:\s*(false|no)\s*$", text, re.M) is not None
        has_changed = re.search(r"^\s*changed_when:", text, re.M) is not None
        has_register = re.search(r"^\s*register:", text, re.M) is not None
        if ro and not has_check:
            problems.append(("E1", path, lineno, name,
                             "changed_when: false but no check_mode: false (skipped under --check)"))
        elif has_register and not has_check and not has_changed:
            problems.append(("W1", path, lineno, name,
                             "registers output but sets neither check_mode nor changed_when"))
    return problems


def main(argv):
    strict = "--strict" in argv
    paths = [a for a in argv if not a.startswith("--")] or DEFAULT_PATHS
    files = []
    for p in paths:
        base = (REPO / p) if not Path(p).is_absolute() else Path(p)
        if base.is_file():
            files.append(base)
        elif base.is_dir():
            files += sorted(base.rglob("*.yml")) + sorted(base.rglob("*.yaml"))
    problems = []
    for f in files:
        problems += lint_file(f)
    errors = [p for p in problems if p[0].startswith("E")]
    warns = [p for p in problems if p[0].startswith("W")]
    for code, path, line, name, msg in errors + warns:
        try:
            rel = path.relative_to(REPO)
        except ValueError:
            rel = path
        print(f"{code} {rel}:{line}  [{name}]  {msg}")
    print(f"\n{len(errors)} error(s), {len(warns)} warning(s) in {len(files)} file(s)")
    return 1 if errors or (strict and warns) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
