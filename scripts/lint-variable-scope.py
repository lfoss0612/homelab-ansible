#!/usr/bin/env python3
"""
Lint script to catch silent empty-variable resolution issues.

Catches two related classes of bugs:
1. Variables referenced with `| default(...)` guards in playbooks that aren't
   defined in scope (only in role defaults, which aren't visible to bare plays).
   The guard causes a silent skip instead of a loud error.
2. host_vars/<name>.yml files that use short hostnames instead of the FQDN the
   inventory actually uses, so the file silently never applies.

Both are "a variable resolved to empty and nothing said so" — silent failures
that look like `failed=0`.

Usage:
    ./scripts/lint-variable-scope.py
    ansible-playbook playbooks/deploy-openclaw.yml --extra-vars @/tmp/lint-issues.json

Exit code 0 if no issues found, 1 if issues found.
"""

import os
import re
import sys
from pathlib import Path
from collections import defaultdict
import json
import tempfile

def parse_inventory(inventory_path):
    """Parse inventory.ini and return list of all inventory hostnames."""
    hostnames = set()
    with open(inventory_path) as f:
        in_group = False
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('['):
                in_group = True
                continue
            if in_group and line and not line.startswith('['):
                # Extract hostname (might have ansible_host after whitespace)
                parts = line.split()
                if parts:
                    hostnames.add(parts[0])
    return hostnames

def check_host_vars_filenames(repo_root, inventory_hostnames):
    """Check that host_vars/*.yml files match inventory hostnames."""
    issues = []
    host_vars_dir = repo_root / 'host_vars'
    if not host_vars_dir.exists():
        return issues

    for host_var_file in host_vars_dir.glob('*.yml'):
        # Extract the hostname from the filename (remove .yml)
        filename_host = host_var_file.stem

        # Check if this matches any inventory hostname
        if filename_host not in inventory_hostnames:
            # Check if it would match if we added a domain
            close_matches = [h for h in inventory_hostnames if h.startswith(filename_host)]
            if close_matches:
                msg = (
                    f"host_vars/{host_var_file.name}: uses short hostname '{filename_host}' "
                    f"but inventory has FQDN. Possible matches: {', '.join(close_matches)}"
                )
            else:
                msg = f"host_vars/{host_var_file.name}: hostname '{filename_host}' not found in inventory"
            issues.append(msg)

    return issues

def extract_role_default_vars(repo_root):
    """Extract configuration variables defined in role defaults/main.yml."""
    role_config_vars = set()

    roles_dir = repo_root / 'collections/ansible_collections/openclaw/node/roles'
    if not roles_dir.exists():
        return role_config_vars

    for role_dir in roles_dir.iterdir():
        if role_dir.is_dir():
            defaults_file = role_dir / 'defaults' / 'main.yml'
            if defaults_file.exists():
                with open(defaults_file) as f:
                    content = f.read()
                    for match in re.finditer(r'^(\w+):\s', content, re.MULTILINE):
                        var_name = match.group(1)
                        # Only include vars that look like configuration (not task artifacts)
                        if any(var_name.startswith(prefix) for prefix in
                               ['openclaw', 'bootstrap', 'opnsense', 'proxmox', 'confirm', 'pve']):
                            role_config_vars.add(var_name)

    return role_config_vars

def extract_variables_in_scope(repo_root):
    """Extract all configuration variables defined in group_vars/ and host_vars/."""
    vars_in_scope = set()

    # Variables from group_vars
    group_vars_dir = repo_root / 'group_vars'
    if group_vars_dir.exists():
        for var_file in group_vars_dir.glob('*.yml'):
            with open(var_file) as f:
                content = f.read()
                for match in re.finditer(r'^(\w+):\s', content, re.MULTILINE):
                    vars_in_scope.add(match.group(1))

    # Variables from host_vars
    host_vars_dir = repo_root / 'host_vars'
    if host_vars_dir.exists():
        for var_file in host_vars_dir.glob('*.yml'):
            with open(var_file) as f:
                content = f.read()
                for match in re.finditer(r'^(\w+):\s', content, re.MULTILINE):
                    vars_in_scope.add(match.group(1))

    return vars_in_scope

def extract_defaulted_role_vars_in_playbooks(repo_root, role_config_vars):
    """Find role config variables referenced with | default(...) guards in playbooks."""
    defaulted_vars = defaultdict(list)

    playbooks_dir = repo_root / 'playbooks'
    if not playbooks_dir.exists():
        return defaulted_vars

    for playbook_file in playbooks_dir.rglob('*.yml'):
        with open(playbook_file) as f:
            content = f.read()
            for match in re.finditer(r'\b(\w+)\s*\|\s*default\s*\(', content):
                var_name = match.group(1)
                # Only check config variables defined in role defaults
                if var_name in role_config_vars:
                    defaulted_vars[var_name].append(str(playbook_file.relative_to(repo_root)))

    return defaulted_vars

def check_defaulted_vars_in_scope(defaulted_vars, vars_in_scope):
    """Check that all defaulted role-config variables are actually in scope."""
    issues = []

    for var_name, playbook_files in defaulted_vars.items():
        if var_name not in vars_in_scope:
            # This variable is in role defaults, has a default guard in a playbook,
            # but is not declared in scope for that playbook
            files_str = '\n    '.join(playbook_files)
            msg = (
                f"Configuration variable '{var_name}' is referenced with | default(...) "
                f"but not found in scope (group_vars/ or host_vars/). "
                f"This will silently skip the task. "
                f"It is defined in a role's defaults/main.yml, which is only visible to "
                f"plays that include that role. "
                f"Declare it in group_vars/ or host_vars/ to make it available to playbooks. "
                f"Found in: {files_str}"
            )
            issues.append(msg)

    return issues

def main():
    repo_root = Path.cwd()

    # Verify we're in the right place
    if not (repo_root / 'playbooks').exists() or not (repo_root / 'inventory.ini').exists():
        print("Error: not in an ansible repo (no playbooks/ or inventory.ini found)", file=sys.stderr)
        sys.exit(1)

    issues = []

    # Check host_vars filenames
    inventory_hostnames = parse_inventory(repo_root / 'inventory.ini')
    issues.extend(check_host_vars_filenames(repo_root, inventory_hostnames))

    # Check role-config variables with default guards are in scope
    role_config_vars = extract_role_default_vars(repo_root)
    vars_in_scope = extract_variables_in_scope(repo_root)
    defaulted_vars = extract_defaulted_role_vars_in_playbooks(repo_root, role_config_vars)
    issues.extend(check_defaulted_vars_in_scope(defaulted_vars, vars_in_scope))

    # Report results
    if issues:
        print("Variable scope lint issues found:\n", file=sys.stderr)
        for i, issue in enumerate(issues, 1):
            print(f"{i}. {issue}\n", file=sys.stderr)
        return 1
    else:
        print("✓ No variable scope lint issues found")
        return 0

if __name__ == '__main__':
    sys.exit(main())
