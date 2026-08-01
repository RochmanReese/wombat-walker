# Wombat Walker v2 — Disk Health and Storage Diagnostics Brief

## Purpose

Add a safe, understandable **Disk health** utility to Wombat Walker v2. It should help a user
answer practical questions about the physical drive behind a mount:

- Is this a whole-drive mount or one partition among several?
- Is the backing storage an NVMe SSD, SATA SSD, spinning HDD, USB enclosure, or USB flash drive?
- Is the device reporting warnings, media errors, high temperature, reduced spare capacity, or
  worn flash endurance?
- Can the drive perform a built-in self-test, and how long will that take?

The feature is diagnostic first. It must never write to a drive, repair a filesystem, erase a
device, or begin a long test without the user explicitly selecting and confirming that action.

## Current implementation status

A deliberately narrow NVMe-only health checker was brought forward into v1 for an immediate drive
migration need and is complete and dogfooded. From Mounted Storage, `[f] Disk health checker
(NVMe)`, or direct `--diskcheck`, lists physical NVMe disks. Selecting one performs the read-only
`nvme smart-log <device> --output-format=json` collection, shows the complete command diagnostic
if it fails, and offers a separate explicit sudo retry when required. Successful checks store a
timestamped SQLite snapshot keyed by serial and render both live and saved reports in readable
three-column layouts with local human-readable timestamps.

Everything else in this brief remains v2 work: SATA SSD/HDD support, USB enclosure and pen-drive
handling, comparative health history, and optional confirmed self-tests.

## Why this belongs in Walker

Walker already explains mounted storage, capacity, usage, mount source, device type, connection,
and full mount path. Disk health is the natural next layer: it tells the user whether the storage
that holds their data is reporting trouble before they begin cleanup, migration, or recovery work.

This is especially useful on systems with several NVMe partitions, old SATA hard drives, USB NVMe
enclosures, removable backup drives, and ordinary USB pen drives that otherwise look similar in a
mount list.

## v2 scope

Add a shared `ww_disk_health` utility, reachable from the mount-list screen and from Utilities.
It should resolve a selected mount to its backing block device and parent physical disk, then show
a read-only health report.

Suggested interaction:

```text
[m] Mounted storage and disk health
  [number] Inspect this mounted filesystem
  [h] Run read-only disk health check
  [t] Offer supported device self-test
  [q] Return
```

The main mount list remains quick. Health commands run only after a user requests them.

## Device categories and expected information

### NVMe SSDs

Preferred sources, in order:

1. `nvme smart-log /dev/nvmeX`
2. `smartctl -a /dev/nvmeX`

Display when reported:

- model, serial, firmware, namespace/device capacity
- critical warning
- composite temperature and warning/critical temperature time
- available spare and spare threshold
- percentage used (vendor endurance estimate; it may exceed 100 and is not a universal health score)
- data units read/written and host read/write command counts where available
- media/data-integrity errors and error-log entries
- power-on hours, power cycles, unsafe shutdowns
- self-test capability, current status, and estimated duration

### SATA SSDs and HDDs

Preferred source:

```text
smartctl -a /dev/sdX
```

Display common SMART data in plain language rather than presenting a raw attribute dump:

- overall SMART assessment
- model, serial, firmware, capacity, interface
- power-on hours, start/stop count, temperature
- reallocated sectors, pending sectors, offline uncorrectable sectors (especially important for HDDs)
- uncorrectable error count and interface CRC errors
- SSD wear/endurance attribute if the vendor exposes one
- rotational status: HDD or SSD
- short/extended self-test support and prior self-test result

Do not assume every vendor uses the same SMART attribute numbers. Preserve raw attribute IDs in a
secondary “technical details” view where useful, but label the friendly interpretation as
vendor-dependent.

### USB external drives and USB NVMe/SATA enclosures

Resolve the parent disk with `lsblk` transport data and show `Connection: USB`.

Attempt SMART pass-through only after the normal read-only check:

```text
smartctl -a -d auto /dev/sdX
```

If that fails, Walker may offer a short, clearly labelled list of safe common bridge types such as
`sat`, `scsi`, or `nvme` only when `smartctl --scan-open` identifies a suitable candidate. Never
cycle through bridge modes blindly and never claim a health result when the enclosure blocks it.

Show an honest result such as:

```text
SMART health unavailable through this USB enclosure.
The drive may be healthy; this enclosure does not expose its diagnostic data to Linux.
```

### USB pen drives / thumb drives

Most consumer USB flash drives do not expose SMART, wear, bad-block, or reliable endurance data.
Walker should identify them as removable USB storage and report:

- mount capacity, used/free space, filesystem, and safe unmount status where available
- whether the device exposes SMART diagnostics
- `Health data not reported by this USB flash device` when it does not

Do not infer health from the absence of errors. Recommend a verified backup when a flash drive is
old, slow, intermittently disconnecting, or showing filesystem errors.

## Safety model

### Read-only health check: default

The default health action only calls read-only information commands (`lsblk`, `findmnt`, `df`,
`nvme smart-log`, and/or `smartctl -a`). It must not modify the disk or filesystem.

### Device self-tests: separate explicit action

If the device supports a built-in SMART/NVMe test, Walker may offer it separately:

- show the exact drive, test kind, and the device-reported estimated duration first
- explain that a short test normally takes minutes; extended tests may take hours
- require a typed confirmation such as `TEST /dev/nvme0`
- poll or provide a later “check test result” action; do not block the full Walker UI for hours
- warn that tests can reduce performance while running but should not alter user files

### Do not make `badblocks` the standard health check

`badblocks` is not a normal NVMe/SSD diagnostic tool. Write-mode tests are destructive and add
unnecessary flash wear; read-only tests can take a very long time and do not replace device health
telemetry. It must not appear in normal menus.

If a future expert-only workflow includes it, it requires a separate explicit brief, clear target
resolution, an unmounted-device check, and repeated destructive warnings. It is out of scope here.

### Filesystem checks are separate

`fsck`, `e2fsck`, NTFS repair, Btrfs scrub, ZFS scrub, and similar filesystem-specific checks are
not drive-health checks. They need their own guarded v2 design because they may require an
unmounted filesystem or have repair implications.

## Privilege and availability handling

- Reading SMART/NVMe logs often needs `sudo`, depending on the distribution and device permissions.
- v2 must use the existing explicit elevation boundary; it must never invoke sudo merely because a
  user opens the mount list.
- First show what data is available unprivileged. Offer a clearly labelled privileged health check
  only after the user chooses it.
- Check for `smartctl` (`smartmontools`) and `nvme` (`nvme-cli`) separately. Explain which optional
  package is missing and which device types it affects.
- A failed or unsupported query is a normal diagnostic outcome, not an application error.

## Suggested report layout

Use Walker’s v2 shared rendering and 114-character frame. Keep the human summary short, then let
the user open technical details.

```text
==================================================================================================================
Disk health — /media/wombat/nvme4tb
Backing device: /dev/nvme1n1p1    Physical disk: /dev/nvme1n1    Connection: USB
==================================================================================================================
Model: Example NVMe SSD                 Media: SSD                 Capacity: 4.10TB
Health: no critical warning             Temperature: 38°C           Power-on: 2,412 hours
Endurance used: 12%                     Media errors: 0             Unsafe shutdowns: 3

[t] Start supported self-test    [r] Refresh health data    [d] Technical details    [q] Return
```

When a data field is unavailable, say `not reported` and explain why in plain language where
known. Never render an invented percentage, temperature, age, or failure prediction.

## Implementation approach

1. Add `ww_disk_health_resolve_mount` to map a mount path to source partition, parent disk,
   transport, rotational status, model, serial, and size via `findmnt`/`lsblk` JSON.
2. Add `ww_disk_health_collect` with small adapters for NVMe, SMART, and unsupported USB flash
   devices. It returns structured fields and warnings, not preformatted command output.
3. Add `ww_disk_health_render_summary` and a technical-details view in the shared v2 UI module.
4. Add explicit elevated collection only when required and selected.
5. Add optional self-test start/status functions with typed confirmation and no blocking wait loop.
6. Create fixtures covering NVMe, SATA HDD, SATA SSD, USB enclosure with pass-through, USB
   enclosure without pass-through, and a USB flash drive with no SMART support.

## Acceptance criteria

- Selecting a mount identifies its backing partition and parent physical disk correctly.
- NVMe/SATA reports show useful available health fields without presenting raw command dumps as the
  primary interface.
- USB bridge/flash-drive limitations are stated clearly and never misreported as a failed drive.
- The default health check is read-only and does not call sudo without explicit user choice.
- Self-tests are optional, confirmed, and non-blocking.
- No destructive media test or filesystem repair command is exposed by this feature.
- Every new v2 function uses the required `ww_` prefix and shared notice/input layer.
