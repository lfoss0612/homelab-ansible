# Ansible Helper Scripts

## lint-variable-scope.py

**Purpose:** Catch silent empty-variable resolution bugs before they slip into production.

Detects two related classes of issues that cause tasks to skip without error:

1. **Role-only configuration variables in playbooks:** A variable defined in a role's `defaults/main.yml` is referenced in a bare playbook with a `| default(...)` guard. The guard causes the variable to resolve to empty and the task to skip silently, with no error signal. The play still reports `failed=0`.

2. **host_vars filename mismatches:** A file like `host_vars/shortname.yml` doesn't match any inventory hostname (which may be an FQDN). Ansible only auto-loads files matching `inventory_hostname`, so the file never applies and variables silently don't get set.

### Usage

Run from the repository root:

```bash
./scripts/lint-variable-scope.py
```

Exit code 0 means no issues found. Exit code 1 means issues were detected (stderr lists them).

### Examples

**Issue 1: Role-only variable referenced in playbook**

If `openclaw_node_hardening` is defined only in a role's `defaults/main.yml` and referenced in a playbook with `| default(...)`:

```
Configuration variable 'openclaw_node_hardening' is referenced with | default(...) 
but not found in scope (group_vars/ or host_vars/). 
This will silently skip the task.
```

**Fix:** Declare it in `group_vars/` or `host_vars/`:

```yaml
# group_vars/openclaw.yml
openclaw_node_hardening: true
```

**Issue 2: host_vars file with wrong hostname**

If `host_vars/pve.yml` exists but the inventory has `pve.home.lab`:

```
host_vars/pve.yml: uses short hostname 'pve' 
but inventory has FQDN. Possible matches: pve.home.lab
```

**Fix:** Rename the file to match:

```bash
mv host_vars/pve.yml host_vars/pve.home.lab.yml
```

### How it works

1. Extracts all configuration variables from role `defaults/main.yml` files
2. Extracts all variables currently in scope from `group_vars/` and `host_vars/`
3. Finds references to role-config variables with `| default(...)` guards in playbooks
4. Reports any role-config variable that is guarded in a playbook but not in scope
5. Also checks that all `host_vars/*.yml` filenames match actual inventory hostnames

### Integration with CI/CD

Add to your CI pipeline:

```bash
./scripts/lint-variable-scope.py || exit 1
```

This ensures configuration variables don't silently skip before the playbook runs.
