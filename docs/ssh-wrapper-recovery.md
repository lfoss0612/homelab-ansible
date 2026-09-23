# SSH Wrapper Recovery Guide

If SSH access to cockpit is broken after SSH wrapper deployment, follow these recovery steps.

## Problem

The SSH wrapper was installed as a broken symlink at `/usr/bin/ssh`, breaking all SSH access to the host. The original SSH binary was backed up to `/usr/bin/ssh.real`.

## Recovery Steps

### Option 1: Direct Console Access (Preferred)

If you have direct console access (KVM, IPMI, serial):

```bash
# Login as root on the console
su -

# Verify the backup exists
ls -la /usr/bin/ssh.real

# Restore the original SSH binary
mv /usr/bin/ssh.real /usr/bin/ssh

# Verify SSH is working
ssh -V

# Check SSH daemon is running
systemctl status ssh

# Restore SSH connectivity
exit
```

### Option 2: Via Cockpit API (If Available)

If Cockpit web UI is still accessible:

1. Login to Cockpit web console
2. Open Terminal
3. Run the recovery commands above

### Option 3: Remote Recovery (If You Have Another Control Node)

If another host can still reach cockpit's kernel/bootloader:

```bash
# On another host that can SSH:
ssh ansible@cockpit.home.lan \
  'sudo mv /usr/bin/ssh.real /usr/bin/ssh && systemctl restart ssh'

# If SSH is completely broken, you may need to:
# - Boot into recovery mode via IPMI
# - Use out-of-band management
# - Restore from backup
```

## Safe Redeployment

Once SSH is restored, redeploy the wrapper safely:

```bash
# Test the wrapper script works locally first
cd /opt/ansible
sudo -u ansible ansible-playbook playbooks/deploy-ssh-access-logging.yml \
  -l cockpit.home.lan \
  --diff \
  --check

# Review the diff carefully, then apply
sudo -u ansible ansible-playbook playbooks/deploy-ssh-access-logging.yml \
  -l cockpit.home.lan \
  --diff

# Verify immediately
ssh cockpit 'ssh -V'
```

## Verification

After recovery or redeployment:

```bash
# Verify SSH wrapper is correctly linked
ssh cockpit 'ls -la /usr/bin/ssh'

# Should show:
# lrwxrwxrwx 1 root root 27 Sep 22 20:00 /usr/bin/ssh -> /usr/local/bin/ssh-wrapper

# Verify original backup exists
ssh cockpit 'ls -la /usr/bin/ssh.real'

# Should show the original SSH binary

# Test SSH logging
ssh cockpit 'tail /var/log/ssh-access.log'

# Should show a new entry for your SSH connection
```

## Prevention

The wrapper deployment now includes:
- Silent error handling (`2>/dev/null || true`)
- Backup verification before replacing SSH
- Symlink safety checks
- Fallback to original binary if wrapper is missing

To deploy safely:

```bash
ansible-playbook playbooks/deploy-ssh-access-logging.yml \
  --check --diff  # Always review first
```

## Logs

If the wrapper fails, check:

```bash
# Ansible playbook logs
journalctl -u ansible-pull -n 100

# SSH daemon logs
journalctl -u ssh -n 100

# Wrapper logs (after recovery)
tail /var/log/ssh-access.log
journalctl -u sshd
```
