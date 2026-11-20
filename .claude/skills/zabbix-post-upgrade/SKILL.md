---
name: zabbix-post-upgrade
description: Upgrade the Zabbix server and agents and check monitoring afterwards: backups, config limits, repo suite per host, agent versions, audit, Execute now. Use for any Zabbix server or agent upgrade, or after a release upgrade that moved a host's apt suite. NOT for adding a dashboard or item (use the zabbix-* playbooks directly).
---

Work in homelab-ansible; all Zabbix API playbooks use the token from `hostvars['zabbix.home.lan']`.

Before (server): back up the database (`mysqldump` of the zabbix schema, or a Proxmox/vzdump restore point of VM 101
via `pre-change-snapshot.yml`) and `/etc/zabbix/zabbix_server.conf`. Read the upgrade notes: DB schema migration
time and any removed items. Upgrade the server first, then agents: agents may be older than the server by a major
within the supported window, not newer.

Agents: the repo suite and major per host come from `zabbix_agent_repo_major` in group_vars/all.yml, and
`fleet-versions` flags a host whose Zabbix repo differs or whose suite does not match its release (a `noble`
suite left on a `resolute` host). Fix repos with `fix-apt-repos.yml`, then `deploy-zabbix-agent.yml` or
`upgrade-to-zabbix-agent2.yml` as appropriate (dry run first).

After: `playbooks/zabbix-audit.yml` (PASS/WARN/FAIL: every inventory host present with the right agent IP,
`os.update.*`, `openclaw.version` and `agent.version` items exist, are supported and fresh, agent vs server
major.minor, cache usage and an enabled trigger on the config cache). Raise `CacheSize` and other limits in
`zabbix_server.conf` if the audit warns (the config cache exhausting blinds monitoring for hours). To see results
the same hour: `playbooks/zabbix-execute-now.yml -e '{"zbx_hosts": [...]}' -e zbx_key_prefix=os.update`
(`--apply` queues the polls; API `task.create` type 6). API token limits: it can `host.update`-style changes
only where a playbook already does; `hostinterface.update` is refused. A NIC rename after a release upgrade
(enp6s18 to ens18) leaves Zabbix items that reference the old name: check them.
