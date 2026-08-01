# Wombat Walker — Session Log

New entries go at the top. Each entry records the working state, verification, next handoff, and any cautions.

---

## Session: 02 August 2026 — Docker storage summary

### What we did

- Added a Docker-explorer header line showing Docker Engine's reported image, container-layer, volume, and build-cache storage categories.
- Kept the existing Docker Desktop virtual-disk capacity and host-allocation line separate, because it is the meaningful host-disk figure and cannot be inferred from container virtual sizes.

### Verification

- Ran Bash syntax and whitespace checks after the rendering and `docker system df` parsing update.

### Where we left off

- Docker now explains both Engine-managed storage categories and Docker Desktop host allocation at the top of its filesystem explorer.

### Watch out for

- Docker Engine categories and Docker Desktop sparse-disk allocation answer different questions; neither should be presented as a particular container's unique disk usage.

---

## Session: 01 August 2026 — Closed: NVMe disk health checker dogfooded

### What we did

- Completed the physical-NVMe disk-health feature brought forward from the v2 diagnostics brief.
- Added Mounted Storage → `[f] Disk health checker (NVMe)` and direct `wombat-walker --diskcheck` entry.
- The picker lists real physical NVMe devices with capacity, model, serial, firmware, and mounted paths.
- Health collection uses read-only `nvme smart-log <device> --output-format=json`; Walker displays complete failed-command diagnostics and asks before using sudo for a single retry.
- Added normalized `disk_health_snapshots` SQLite storage, saved in-app health history, readable local timestamps, and aligned three-column live/saved reports.
- Fixed real-world compatibility issues found during dogfooding against `nvme-cli 2.8`, including positional command ordering and Kelvin-to-Celsius conversion.

### Verification

- Ran `bash -n scripts/wombat-walker.sh`, `python3 -m py_compile scripts/wombat-walker-db.py`, and `git diff --check` throughout implementation.
- User tested all three physical NVMe drives on the PC using an explicit sudo retry; live checks, saved health reports, history, and readable three-column output worked.
- Reports correctly surfaced healthy zero-error drives and rendered health values including temperature, spare, endurance, lifetime writes, and unsafe-shutdown count.

### Where we left off

- The NVMe health checker is working v1 functionality for drive-migration decisions.
- Next diagnostics work remains v2: direct-SATA SSD/HDD SMART support, USB bridge/enclosure handling, comparison across snapshots, and separately confirmed self-tests.

### Watch out for

- `nvme-cli` is an optional package. Walker reports when it is missing; it must be installed by the user or system administrator.
- Some systems require sudo even for a read-only SMART log. Walker must continue to request it only after an explicit user choice and must never elevate normal filesystem actions.
- Never present `Percentage Used` as exact remaining capacity; it is a vendor endurance estimate. USB SMART unavailability means an unsupported bridge, not necessarily a failed drive.

---

## Session: 01 August 2026 — Closed: mount clarity and v2 disk-health planning

### What we did

- Fixed `wombat-walker --docker`: `[q]` now returns to the main host explorer, matching Utilities → Docker, instead of exiting to the shell.
- Reworked Mounted Storage into readable 114-character blocks showing device, filesystem, UUID, label, total/used/free space, usage percentage, full mount path, backing device classification, and connection type.
- Added detection for a partition that occupies virtually an entire physical disk, reported as `Whole drive`; connection detection distinguishes USB, internal NVMe, and internal SATA where the system reports it.
- Wrote `briefs/WOMBAT-WALKER-DISK-HEALTH-BRIEF.md` for a future v2 read-only disk-health utility covering NVMe, SSD, HDD, USB enclosures, and USB flash drives.
- Brought forward a narrow immediate-use version for physical NVMe drives: Mounted Storage → `[f] Disk health checker (NVMe)` resolves physical drives, performs a read-only health collection, requests sudo only when needed, renders results, and saves normalized snapshots in SQLite.

### Verification

- Ran `bash -n scripts/wombat-walker.sh`, `python3 -m py_compile scripts/wombat-walker-db.py`, and `git diff --check` for relevant changes.
- Rendered the live mount-list output against the development system after each mount-display change.

### Where we left off

- v1 remains the working day-to-day application; `v1.0-working` remains the original dogfooded baseline at `e7a32c6`.
- The basic NVMe health check and saved in-app history are available in v1 for immediate drive-migration checks. Broader SATA/HDD/USB health support and self-tests remain deferred to v2.

### Watch out for

- A source ending in `p1`, `p2`, etc. is technically a partition even when it occupies the whole physical drive; Walker presents the more useful `Whole drive` label only when it covers at least 99% of its parent disk.
- USB enclosures and pen drives frequently do not expose SMART/NVMe diagnostics. Treat unavailable health telemetry as unsupported, not as a failed drive.

---

## Session: 01 August 2026 — Closed: v1 dogfooding complete

### What we did

- Completed and dogfooded Walker's host search flow: scope-first search, automatic selected-folder refresh, multi-word matching, pagination, ordering, size refinement, retry with new words, manual paths including `~/`, and actions from search results.
- Improved host browsing and management: persistent display settings, useful owner display, hidden-item control, readable cached-size wording, global path entry, shell access, and bottom-of-screen notices.
- Built and dogfooded Docker as a first-class Walker workspace: container inventory, live filesystem browsing, saved scans/search, storage connections, persistent-data calculation, editing live files, safety locks, individual and bulk lifecycle actions, and guarded purge receipts.
- Added Docker management protections: stopped containers lock by default; running containers must be stopped before remove/purge; bulk stop locks containers; destructive actions require explicit typed confirmation.
- Refined the Docker and search UI through real use, including consistent separators, result grouping, `Runs as`, navigation, and visible operation receipts.
- Committed and pushed the tested v1 code baseline as `e7a32c6 Mark Walker v1 tested and stable`.

### Verification

- User dogfooded every Walker action, including Docker purge, against real host and Docker data.
- Repeated `bash -n scripts/wombat-walker.sh`, `python3 -m py_compile scripts/wombat-walker-db.py` when Python changed, and `git diff --check` passed during implementation.

### Where we left off

- **v1 is the stable working reference.** The tested source baseline is tagged `v1.0-working` at `e7a32c6`.
- Next work is v2 only: copy or branch from the v1 baseline and follow `briefs/WOMBAT-WALKER-V2-REFACTORING-BRIEF.md` incrementally.

### Watch out for

- Do not casually refactor the v1 Bash entry point. Use it as the behavioural comparison oracle.
- Preserve Walker's safety model and its bottom-notice rule: errors and notices belong below content and immediately above navigation.
- `pics/` contains user-owned untracked assets. Do not add or delete them unless explicitly asked.
