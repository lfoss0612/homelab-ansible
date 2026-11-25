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
  E2  `uri` task that only reads (an HTTP GET/HEAD, or a Zabbix JSON-RPC call whose method
      is `*.get`, `*.login`, `apiinfo.version`) and has `register:` but no `check_mode:`.
      `uri` is skipped under --check like `command`, so the registered value is empty in a
      dry run. A write (POST/PUT/PATCH/DELETE, or an RPC `*.create/update/delete/...`) is
      correctly skipped and is not flagged.
  W2  `uri` task with `register:`, no `check_mode:`, and a method the lint cannot classify
      as a read or a write (a templated `method:`). Decide which it is.

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
URI_KEY = re.compile(r"^\s*(?:-\s+)?(?:ansible\.builtin\.)?uri:")
READ_RPC = re.compile(r"^(?:[a-z]+\.(?:get|login|checkAuthentication|logout)|apiinfo\.version)$")
WRITE_HTTP = {"POST", "PUT", "PATCH", "DELETE"}
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


def classify_uri(text):
    """Return 'read', 'write' or 'unknown' for a uri task's text."""
    http = None
    rpc = []
    for m in re.finditer(r"^\s*method:\s*[\"']?([^\"'\s#]+)[\"']?", text, re.M):
        v = m.group(1)
        if "." in v or "{{" in v and "." in v:
            rpc.append(v)
        else:
            http = v
    if "{{" in (http or ""):
        return "unknown"
    http = (http or "GET").upper()
    if http in ("GET", "HEAD"):
        return "read"
    if http in WRITE_HTTP:
        if rpc:
            kinds = {("read" if READ_RPC.match(r) else "unknown" if "{{" in r else "write") for r in rpc}
            if kinds == {"read"}:
                return "read"
            if "unknown" in kinds:
                return "unknown"
        return "write"
    return "unknown"


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
        if re.search(r"^\s*when:.*ansible_check_mode", text, re.M):
            continue  # deliberately gated on check mode, nothing to decide
        is_uri = any(URI_KEY.match(l) for l in mine)
        if not is_uri and not any(MODULE_KEY.match(l) for l in mine):
            continue
        name = next((re.sub(r"^\s*-?\s*name:\s*", "", l).strip("\"' ") for l in mine if "name:" in l), "(unnamed)")
        has_check = re.search(r"^\s*check_mode:", text, re.M) is not None
        ro = re.search(r"^\s*changed_when:\s*(false|no)\s*$", text, re.M) is not None
        has_changed = re.search(r"^\s*changed_when:", text, re.M) is not None
        has_register = re.search(r"^\s*register:", text, re.M) is not None
        if is_uri:
            if has_register and not has_check:
                kind = classify_uri(text)
                if kind == "read":
                    problems.append(("E2", path, lineno, name,
                                     "uri read with register: but no check_mode: false (skipped under --check)"))
                elif kind == "unknown":
                    problems.append(("W2", path, lineno, name,
                                     "uri with register: and no check_mode:, cannot tell a read from a write"))
            continue
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
