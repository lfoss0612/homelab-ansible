# SMART Drive Monitoring via Zabbix

Disk health for the four hosts with physical disks — `pbs`, `pve`, `pve-ai`,
`pve-router` — pushed into Zabbix as low-level discovery plus trapper values, so
failing hardware surfaces as an alert instead of via a monthly manual check.

## The two halves, and why you need both

| | Playbook | Creates |
|---|---|---|
| Host side | `playbooks/smart-monitor.yml` | `/usr/local/bin/smart-monitor`, its systemd service and 30-minute timer |
| Server side | `playbooks/smart-monitor-zabbix-setup.yml` | the discovery rule, item/trigger prototypes, aggregate items and triggers |

Running only the host side pushes values the server accepts and then silently
discards, because no matching item exists. Running only the server side creates
items nothing ever feeds. **Neither half fails loudly on its own** — that is the
characteristic failure of this whole area, so run both:

```bash
cd /opt/ansible
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor.yml --check --diff
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor.yml
sudo -n -H -u ansible ansible-playbook playbooks/smart-monitor-zabbix-setup.yml
```

## Which hosts

The `[smart_monitored]` inventory group, **not** `[proxmox_hosts]`. Membership is
a monitoring decision rather than a topology one: `pbs` is bare metal rather than
a hypervisor, so it does not belong in the Proxmox group — and being outside it
is exactly why `pbs` had no SMART coverage at all until 2026-08-25, despite being
the host under the most disk pressure in the fleet.

**Do not add a VM.** Virtual disks expose no SMART data — verified on `omv`,
where every `/dev/sd*` returns an empty model and an empty health line — so the
result is items that can never collect. That is worse than no monitoring,
because it looks like monitoring.

## What gets created

Per-drive objects come from **low-level discovery**, not from a list in the
playbook. The script sends a `smart.discovery` payload describing what it
actually found:

```json
[{"{#DEV}":"sda","{#TYPE}":"ata","{#MODEL}":"WDC WD101EFBX-68B0AN0"},
 {"{#DEV}":"nvme0","{#TYPE}":"nvme","{#MODEL}":"KBG50ZNS512G NVMe KIOXIA 512GB"}]
```

Zabbix stamps out one set of items and triggers per entry. Swap a disk and the
items follow within 30 minutes, with no playbook edit.

> This replaced hardcoded per-host drive lists, and the reason is instructive.
> The old lists said `pve` had `sda`–`sdg`. It actually has `sda`–`sde` plus
> `nvme0` and `nvme1`, so Zabbix held items for two drives that no longer existed
> and none for the two NVMes that did, while `pve-router` had only the aggregate
> item because the play had no per-drive task for it. The lists were correct when
> written and rotted in silence.

### Items

| Key | Meaning |
|---|---|
| `smart.status` | Worst-of across all drives: 0 healthy, 1 failing, 2 unreadable/none |
| `smart.drives.count` | How many drives `smartctl --scan` found |
| `smart.drive[{#DEV},status]` | Per drive: 0 passed, 1 FAILED, 2 unreadable |
| `smart.drive[{#DEV},failed_attrs]` | 1 when an attribute is below threshold, or NVMe reports critical warning / media errors |
| `smart.drive[{#DEV},temperature]` | °C |

`failed_attrs` is the one to care about. Overall health stays `PASSED` until a
drive is nearly gone, whereas a reallocated-sector count crossing its threshold
usually precedes that by weeks.

### Triggers

Per drive: FAILED health (High), failed attributes (High), unreadable (Warning),
over temperature (Warning). Aggregate: a drive is failing (High), a drive is
unreadable (Warning), and —

**`nodata(/<host>/smart.status,2h)=1` — monitoring has stopped reporting.**

This is the most important trigger of the set. Every other one depends on the
script continuing to run, and none of them notice if it stops. The timer fires
every 30 minutes, so two hours is four missed runs: long enough to ride out a
reboot, short enough to catch a monitor that has quietly died. The fleet-update
notifier had to learn this the hard way, where a dead notifier was
indistinguishable from a healthy fleet for two weeks.

### Temperature thresholds

Context macros, set per host, so one trigger prototype serves both drive classes:

| Macro | Default | Applies to |
|---|---|---|
| `{$SMART.TEMP.MAX:"ata"}` | 55 | spinning disks and SATA SSDs |
| `{$SMART.TEMP.MAX:"nvme"}` | 75 | NVMe |
| `{$SMART.TEMP.MAX}` | 60 | fallback, `{#TYPE}` unknown |

The two scales are not interchangeable. Measured across the fleet 2026-08-25,
healthy ATA drives sat at 46–47 °C while healthy NVMe ran 62–68 °C — `pbs`'s
KIOXIA idles at 68 °C. A single fleet-wide number would either cry wolf on every
NVMe or never fire on a cooking hard disk. Override per host in the Zabbix UI;
the playbook reconciles the value if you change it in the playbook instead.

## Manual testing

```bash
sudo /usr/local/bin/smart-monitor          # prints a per-drive table, then pushes
systemctl list-timers smart-monitor.timer
journalctl -u smart-monitor.service -n 20
```

The script prints what it found and logs the `zabbix_sender` result. It exits
non-zero only when it could not *report* — a failing drive is a normal outcome to
report and exits 0, so a red `smart-monitor.service` means a broken monitor, not
a bad disk.

## Troubleshooting

### Values are sent but nothing appears in Zabbix

The server accepts the connection and then discards values it has no item for,
so read the counters rather than the exit status. The script does this for you
and warns:

```
WARNING: Zabbix discarded values sent as host 'pve.home.lan'.
```

Two causes, in order of likelihood:

1. `smart-monitor-zabbix-setup.yml` has not been run for that host.
2. The name the values are sent under does not match the Zabbix host name. The
   script takes it from `Hostname=` in the agent config, trying
   `/etc/zabbix/zabbix_agent2.conf` then `/etc/zabbix/zabbix_agentd.conf`.

That path is a **list on purpose**. All four hosts run agent2; a hardcoded
`zabbix_agentd.conf` is what silently disabled the fleet-update notifier after
the agent2 migration, and the same hardcoded path in the old version of
`smart-monitor.yml` made the deploy skip all four hosts while reporting success.

### Per-drive items are missing

They only exist after the host has pushed a `smart.discovery` payload. Force it:

```bash
systemctl start smart-monitor.service
```

Then check Data collection → Hosts → *host* → Discovery rules → SMART drive
discovery.

### A removed drive's items are still there

Expected. Zabbix **disables** resources a discovery stops returning rather than
deleting them (`lifetime: 30d`), which keeps history readable across a swap. The
consequence is that the raw unsupported-item count is the wrong thing to alert
on — measure `{state: 1, status: 0}`, unsupported *and enabled*.

### Deleting objects

`discoveryrule.delete`, `itemprototype.delete` and `usermacro.delete` are all
**refused** to the API token these playbooks use (verified 2026-08-25), while
`.create` and `.update` are granted. Anything that genuinely needs deleting has
to go through the UI or a wider token; the playbooks are written to create or
update, never to require a delete.

## Known gap

The `Seagate ST2000DL003` with an active SMART failure — the drive that motivated
this work — is **not on any of these four hosts**. It was not found on `pbs`,
`pve`, `pve-ai` or `pve-router` on 2026-08-25, and `omv` exposes no SMART data
through its virtual disks. Wherever that drive is attached, this setup does not
currently watch it.
