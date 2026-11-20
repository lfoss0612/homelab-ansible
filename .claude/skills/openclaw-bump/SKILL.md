---
name: openclaw-bump
description: Bump the OpenClaw version (and Node.js floor) across the fleet safely: rehearse against a copy of the state, snapshot, gateway, canary node, rest, approvals, validate, then the pin. Use when a newer OpenClaw release is available or `openclaw_version` in group_vars/openclaw.yml changes. NOT for a general fleet update (fleet-update-cycle) or a broken node (diagnose first).
---

Work in homelab-ansible. Use the wrappers; dry run first; ask before `--apply` and before pushing to main
(a push activates the weekly timer).

1. **Read** `npm view openclaw@<v> engines.node` and the release notes. Node: the declared range AND the notes
   (a security floor can exceed it). Check Node's lifecycle in the `fleet-versions` report. A Node major change
   follows the major-bump order in docs/execution-model.md (canary, rest, gateway last, restart, validate).
2. **Rehearse**: `playbooks/openclaw-bump-rehearsal.yml -e rehearsal_version=<v>` (add
   `rehearsal_hosts=openclaw_gateway,pve.home.lan,k8s-worker.home.lan` for one of each shape). It runs the NEW
   version's `doctor` against a COPY of the state. PASS: go. REVIEW or FAIL: read the lines; a refused jump means
   an intermediate release is needed: set `openclaw_upgrade_path: [<hop>, ...]` (at most three hops) so
   `update-openclaw.yml` walks them. INCONCLUSIVE: nothing was tested (state lock); fix and rerun.
3. **Pin**: edit `openclaw_version` (and `openclaw_node_min_version`) in `group_vars/openclaw.yml`, commit. Never
   leave the gateway migrated while the pin in git is older: the timer's downgrade guard exists for this.
4. **Dry run** `update-openclaw.yml`, then `--apply`: it snapshots the gateway VM first, migrates the gateway
   (stops services, `doctor --fix`, health gate), canary node, the rest, approves pairing and fixes node names.
5. **Validate** `playbooks/validate-openclaw.yml` on all hosts, then the fleet-versions report.
6. **Push** the pin only with the user's approval.

Failure catalog (each has a step above): doctor needs the gateway stopped and exits 1 even on success (the
health gate is the real check); legacy agent DB refusal ("unreleased session schema ... run X first": hop);
HAProxy `proxy_attribution_required` and `gateway.trustedProxies`; node sandbox cache dir (`XDG_CACHE_HOME`);
retired `node.json`; unversioned `exec-approvals.json`; root-owned `~/.openclaw/plugins`; two pairing queues;
node shown under the wrong name after migration (`approve-openclaw-nodes.yml` renames). Rollback: the VM
snapshot `pre-openclaw-<v>-<date>` and `/var/backups/openclaw-state-<stamp>.tar.gz`. pve-router has no `claude`
user by design (`openclaw_manage_claude_user: false`).
