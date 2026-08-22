# SMART Drive Monitoring via Zabbix

This document describes the SMART (Self-Monitoring, Analysis and Reporting Technology) monitoring setup that sends drive health alerts to Zabbix from Proxmox hosts.

## Overview

The SMART monitoring solution consists of:

1. **Monitoring Script** (`scripts/smart-monitor.sh`) — Runs on each Proxmox host, checks all drives via `smartctl`, and reports metrics to Zabbix using `zabbix_sender`.

2. **Systemd Timer** (`smart-monitor.timer`) — Executes the monitoring script every 30 minutes.

3. **Zabbix Agent** — Already configured on PVE hosts (Server=10.0.5.9).

4. **Zabbix Items** (server-side) — Receive the metrics sent by `zabbix_sender` and trigger alerts.

## Deployment

Deploy to all Proxmox hosts:

```bash
cd /opt/ansible
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor.yml --check --diff
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor.yml
```

### Optional: Configure smartd to Execute on Errors

By default, the monitoring script runs every 30 minutes via a systemd timer. To also execute the script immediately when smartd detects an error:

```bash
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor.yml \
  -e smart_monitor_exec_on_error=true
```

This modifies `/etc/smartmontools/smartd.conf` to invoke the script when errors occur, enabling real-time alerts.

## Metrics Sent to Zabbix

The script sends the following metrics for each drive (e.g., `/dev/sda` → `sda`):

| Metric | Type | Values | Description |
|--------|------|--------|-------------|
| `smart.status` | Integer | 0, 1, 2 | Overall status: 0=healthy, 1=failure, 2=error |
| `smart.drive.{dev}.status` | Integer | 0, 1, 2 | Per-drive status: 0=passed, 1=failed, 2=error |
| `smart.drive.{dev}.temperature` | Integer | °C | Drive temperature in Celsius |
| `smart.drive.{dev}.failed_attrs` | Integer | 0, 1 | Whether drive has failed SMART attributes |

## Zabbix Configuration

### 1. Create Host for PVE (if not already present)

In Zabbix frontend, create a host for each Proxmox node:

- **Hostname:** `pve.home.lan` (or `pve-ai.home.lan`, `pve-router.home.lan`)
- **Visible name:** PVE (or PVE-AI, PVE-Router)
- **Host groups:** Proxmox (or create as needed)
- **Agent interface:** 10.0.5.4:10050 (update IP for each host)
- **Templates:** (optional) Linux by Zabbix agent (for additional OS metrics)

### 2. Create Items for SMART Metrics

For each Proxmox host, create these items. **Note:** Items are "trapper" type, meaning they receive values pushed via `zabbix_sender`, not pulled by the agent.

#### Overall SMART Status Item

- **Name:** SMART status
- **Type:** Trapper
- **Key:** `smart.status`
- **Data type:** Numeric (unsigned)
- **Description:** Overall SMART health: 0=healthy, 1=issue, 2=error

#### Per-Drive Items (example for `/dev/sda`)

For each detected drive, create items. Drives are identified by their short names (`sda`, `sdb`, `sdc`, `sdd`).

**Drive Status Item**

- **Name:** SMART status - sda
- **Type:** Trapper
- **Key:** `smart.drive.sda.status`
- **Data type:** Numeric (unsigned)
- **Description:** Drive status: 0=passed, 1=failed, 2=error

**Drive Temperature Item**

- **Name:** SMART temperature - sda
- **Type:** Trapper
- **Key:** `smart.drive.sda.temperature`
- **Data type:** Numeric (unsigned)
- **Units:** °C
- **Description:** Drive temperature

**Drive Failed Attributes Item**

- **Name:** SMART failed attributes - sda
- **Type:** Trapper
- **Key:** `smart.drive.sda.failed_attrs`
- **Data type:** Numeric (unsigned)
- **Description:** Whether drive has failed attributes: 0=none, 1=present

### 3. Create Triggers for Alerts

Create triggers to alert when SMART issues are detected:

#### Trigger: Drive Health Failed

- **Name:** SMART drive failure on {HOST.NAME}
- **Severity:** High
- **Expression:** `{<hostname>:smart.status.last()} = 1`
- **Recovery:** `{<hostname>:smart.status.last()} = 0`
- **Description:** A drive is reporting SMART failures

#### Trigger: Drive Overheating (Example)

- **Name:** SMART drive overheating: {HOST.NAME}
- **Severity:** Medium
- **Expression:** `{<hostname>:smart.drive.sda.temperature.last()} > 50` (adjust threshold)
- **Recovery:** `{<hostname>:smart.drive.sda.temperature.last()} <= 45`
- **Description:** Drive temperature exceeds safe threshold

#### Trigger: SMART Tool Error

- **Name:** SMART monitoring error on {HOST.NAME}
- **Severity:** Medium
- **Expression:** `{<hostname>:smart.status.last()} = 2`
- **Recovery:** `{<hostname>:smart.status.last()} < 2`
- **Description:** SMART monitoring script encountered an error

## Manual Testing

Test the setup without waiting for the timer:

```bash
# Run the monitoring script manually
sudo /usr/local/bin/smart-monitor

# Check the systemd timer status
systemctl status smart-monitor.timer
systemctl list-timers smart-monitor.timer

# View recent runs in the journal
journalctl -u smart-monitor.service -n 20 --follow
```

## Troubleshooting

### Script fails to send to Zabbix

Check that the Zabbix server IP and port are correct:

```bash
grep -E '^Server=|^Port=' /etc/zabbix/zabbix_agentd.conf
```

The script defaults to `10.0.5.9:10051`. If different, update the environment variables in `smart-monitor.service`.

### smartctl returns no data

Run smartctl directly to diagnose:

```bash
sudo smartctl --scan
sudo smartctl -a /dev/sda
```

If it returns an error, check that smartmontools is installed and the drives are detected:

```bash
sudo systemctl status smartmontools
sudo smartctl --version
```

### Timer not running

Check the timer status:

```bash
systemctl status smart-monitor.timer
systemctl list-timers --all smart-monitor.timer
```

To debug timer execution:

```bash
journalctl -u smart-monitor.timer -n 20
journalctl -u smart-monitor.service -n 20
```

### Zabbix not receiving metrics

Verify `zabbix_sender` connectivity:

```bash
/usr/bin/zabbix_sender -z 10.0.5.9 -p 10051 -s "pve.home.lan" -k "smart.status" -o 0 -v
```

Expected output shows the value was accepted by the Zabbix server.

## Architecture

```
Proxmox Host (e.g., pve.home.lan)
├── /dev/sda, /dev/sdb, /dev/sdc, /dev/sdd (drives)
├── smartd daemon (system service)
├── smart-monitor.timer (systemd timer, every 30min)
│   └── smart-monitor.service (runs script)
│       └── /usr/local/bin/smart-monitor (script)
│           ├── Runs: smartctl -a /dev/sdX
│           ├── Parses SMART status
│           ├── Sends metrics via zabbix_sender
│           └── Reports to Zabbix Server (10.0.5.9:10051)
└── zabbix_agentd (already configured)
    └── Hostname: pve.home.lan
```

## See Also

- [smartmontools documentation](https://www.smartmontools.org/)
- [smartctl man page](https://www.smartmontools.org/wiki/Smartctl)
- [Zabbix Trapper Items](https://www.zabbix.com/documentation/current/en/manual/config/items/itemtypes/trapper)
- [zabbix_sender man page](https://www.zabbix.com/documentation/current/en/manual/appendix/commands/zabbix_sender)
