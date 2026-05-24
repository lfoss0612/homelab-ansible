# Ansible Bootstrap User Setup
This repository contains an Ansible playbook used to bootstrap a dedicated automation user (`ansible`) across all managed nodes. The bootstrap process is required 
because initial SSH access is performed using an existing administrative user (`lfoss`), after which the `ansible` user is created and configured for passwordless 
automation. ---
## Goal
We transition from: ``` lfoss (manual/admin login) ``` to: ``` ansible (automation user for all Ansible runs) ``` ---
## Important Design Rule
During bootstrap: * SSH must use `lfoss` * The `ansible` user does NOT yet exist on all systems * Inventory may default to `ansible`, which must be overridden After 
bootstrap: * All Ansible operations should use `ansible` * SSH keys are used exclusively (no passwords) ---
## Files
* `ansible-user.yml` → Bootstrap playbook * `inventory.ini` → Target hosts definition * `/opt/ansible/keys/id_ansible.pub` → Public key deployed to nodes 
---
## Bootstrap Execution
### 1. Ensure SSH access works manually
```bash ssh lfoss@pve.home.lan ``` If this fails, Ansible will also fail. ---
### 2. Run the bootstrap playbook
You MUST override the inventory default user during bootstrap: ```bash ansible-playbook -i inventory.ini ansible-user.yml \ -u lfoss \ -e ansible_user=lfoss \ 
  --become
```
### Why this is required
* `-u lfoss` → forces SSH login user * `-e ansible_user=lfoss` → overrides inventory default (`ansible`) * `--become` → allows privilege escalation ---
## What the playbook does
### 1. Creates ansible user
* system user * bash shell * home directory
### 2. Sets up SSH access
* creates `/home/ansible/.ssh` * installs authorized_keys from: `/opt/ansible/keys/id_ansible.pub`
### 3. Fixes permissions
* correct ownership of `/home/ansible`
### 4. Configures sudo
* `ansible ALL=(ALL) NOPASSWD:ALL`
### 5. Locks password login
* disables password authentication ---
## After Bootstrap
### Test SSH
```bash ssh ansible@pve.home.lan ``` Should work using SSH keys only. ---
### Switch to production mode
Update `inventory.ini`: ```ini [all:vars] ansible_user=ansible ``` Then run: ```bash ansible-playbook -i inventory.ini site.yml ``` ---
## Troubleshooting
### Permission denied (publickey,password)
Most common cause: wrong SSH user (ansible instead of lfoss) Fix: ```bash ansible-playbook -i inventory.ini ansible-user.yml \ -u lfoss \ -e ansible_user=lfoss ``` 
---
### Test SSH key manually
```bash ssh -i /opt/ansible/keys/id_ansible ansible@host ``` Ensure permissions: ```bash chmod 600 /home/ansible/.ssh/id_ansible ``` ---
## Recommended Architecture
* lfoss → bootstrap/admin access * ansible → automation user * SSH keys only for ansible * password SSH disabled for automation ---
## Outcome
After bootstrap: * ansible user exists on all nodes * passwordless sudo enabled * SSH key auth configured * Ansible fully automated
