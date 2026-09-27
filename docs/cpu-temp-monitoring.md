# CPU Temperature Monitoring via Zabbix

CPU sensor temperature for the four physical hosts — `pbs`, `pve`, `pve-ai`,
`pve-router` — pushed into Zabbix as low-level discovery plus trapper values.
None of the four had any CPU-package-temperature monitoring before this: only
per-drive SMART temperatures existed (see [smart-monitoring.md](smart-monitoring.md)),
surfaced 2026-09-19 when a question about whether fixing a crashlooping pod
lowered `pve`'s CPU temperature turned out to be unanswerable from monitoring.

Structurally a direct copy of the SMART monitoring pattern — same two-halves
split, same LLD shape, same get-then-create Zabbix setup. Read
[smart-monitoring.md](smart-monitoring.md) for the fuller "why" behind choices
repeated here without re-explaining them.

## The two halves, and why you need both

| | Playbook | Creates |
|---|---|---|
| Host side | `playbooks/cpu-temp-monitor.yml` | `/usr/local/bin/cpu-temp-monitor`, its systemd service and 30-minute timer, plus `lm-sensors`/`jq` and a `sensors-detect --auto` run |
| Server side | `playbooks/cpu-temp-monitor-zabbix-setup.yml` | the discovery rule, item/trigger prototypes, aggregate item and triggers |

```bash
cd /opt/ansible
sudo -n -H -u ansible ansible-playbook playbooks/cpu-temp-monitor.yml --check --diff
sudo -n -H -u ansible ansible-playbook playbooks/cpu-temp-monitor.yml --limit pve.home.lan,pve-ai.home.lan,pbs.home.lan
# confirm sensors output and a real push look sane before including pve-router
sudo -n -H -u ansible ansible-playbook playbooks/cpu-temp-monitor.yml --limit pve-router.home.lan
sudo -n -H -u ansible ansible-playbook playbooks/cpu-temp-monitor-zabbix-setup.yml
```

## Which hosts, and pve-router's extra care

The `[cputemp_monitored]` inventory group — same four members as
`[smart_monitored]`/`[oom_monitored]` today, kept separate because "has a CPU
to watch" is expected to diverge from the other two questions over time (see
the comment in `inventory.ini`).

No `confirm_pve_router` gate: the nearest precedent, `smart-monitor.yml`,
targets the same host set with the same "install an agent, read hardware"
shape and doesn't gate it either — that mechanism is reserved for
hypervisor-config-scope plays. But `sensors-detect` loads kernel modules,
a step up from SMART's read-only `smartctl` calls, so treat it with the
sequencing above rather than a blind fleet-wide run: the other three hosts
first, then `pve-router` alone with its `sensors-detect` output reviewed
before trusting it.

`sensors-detect --auto` takes the *default* answer at every prompt rather
than forcing yes to everything — safe probes default to yes, the riskier
legacy ISA/SMBus force-probes default to no and stay no under `--auto`. The
playbook also wraps it in `timeout 120` with stdin from `/dev/null` as a hard
backstop against a future lm-sensors version adding a prompt `--auto` doesn't
cover.

## What gets created

Per-sensor objects come from **low-level discovery**, not a list in the
playbook — chip drivers differ across the fleet (`coretemp` on Intel,
`k10temp` on AMD Zen, etc.), which is exactly the problem LLD solves here too.
The script only reports chips matching a known-CPU-driver allowlist
(`coretemp`, `k10temp`, `k8temp`, `zenpower`, `via-cputemp`); `sensors -j` also
exposes NVMe composite temperature via the kernel's own hwmon registration —
without that filter, a drive's temperature would get discovered and mislabeled
`CPU nvme-... (Composite): temperature`, which SMART already tracks correctly
under its own naming. A host whose chip isn't in the allowlist logs the raw
chip names `sensors -j` actually found, so a new driver can be added rather
than silently skipped.

Unlike SMART's drives, there is no rotating-enumeration problem to work around
(a sensor's chip+feature name is stable, not handed out like a USB drive
letter), so the LLD key is just a sanitized `<chip>_<feature>` id — no
serial/device-letter split needed.

### Items

| Key | Meaning |
|---|---|
| `cputemp.max` | Highest reading across every discovered sensor on the host |
| `cputemp.sensor[{#ID},value]` | One reading, °C |

### Triggers

Per sensor: over `{$CPUTEMP.MAX}` (Warning). Aggregate: over threshold
(Warning), and — same as SMART's most important trigger —
`nodata(/<host>/cputemp.max,2h)=1`, "monitoring has stopped reporting".

### Temperature threshold

| Macro | Default | Applies to |
|---|---|---|
| `{$CPUTEMP.MAX}` | 85 | every discovered CPU sensor on the host |

**This is a starting estimate, not a measured one** — unlike SMART's 55/75,
which came from real fleet data, no CPU temperature had ever been read on any
of these four hosts before this monitor existed. 85°C is comfortably under
the ~95-100°C throttle/critical point on modern Intel and AMD parts. Override
per host in the Zabbix UI once real readings are seen; revisit the default
here too if the fleet runs consistently hotter or cooler than expected.

## Dashboard

`playbooks/zabbix-cpu-temp-dashboard.yml` builds **CPU Temperature**: active
problems, a per-host roll-up, a honeycomb with one cell per discovered sensor,
and a temperature history graph.

```bash
sudo -n -H -u ansible ansible-playbook playbooks/zabbix-cpu-temp-dashboard.yml
```

Same by-name-pattern coupling as the SMART dashboard: renaming
`cputemp_item_prototypes` in the setup playbook silently empties the matching
widget here.

## Manual testing

```bash
sudo /usr/local/bin/cpu-temp-monitor    # prints a per-sensor table, then pushes
systemctl list-timers cpu-temp-monitor.timer
journalctl -u cpu-temp-monitor.service -n 20
```

Exits non-zero only when it could not *report* (missing tooling, no sensors
found, or no recognized CPU chip) — a hot-but-reporting CPU is a normal
outcome and exits 0, so a red `cpu-temp-monitor.service` means a broken
monitor, not a hot machine.

## Troubleshooting

Same two failure modes as SMART (see
[smart-monitoring.md](smart-monitoring.md#values-are-sent-but-nothing-appears-in-zabbix)):
values sent under the wrong Zabbix host name, or `cpu-temp-monitor-zabbix-setup.yml`
not yet run for that host. The script warns on stderr/journal either way rather
than trusting `zabbix_sender`'s exit code, which reports success for the
connection even when the server discards every value.

If no sensors are found at all, or a host logs "no chip matched the known CPU
driver list", `sensors-detect` may not have found this board's chip, or the
chip is real CPU hardware under a driver name not yet in
`CPU_CHIP_PATTERN` in `scripts/cpu-temp-monitor.sh` — check the logged raw
chip list and extend the allowlist rather than assuming the host has no
sensor at all.
