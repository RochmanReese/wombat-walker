# Wombat Walker — Session Log

New entries go at the top. Each entry records the working state, verification, next handoff, and any cautions.

---

## Session: 01 August 2026 — Closed: mount clarity and v2 disk-health planning

### What we did

- Fixed `wombat-walker --docker`: `[q]` now returns to the main host explorer, matching Utilities → Docker, instead of exiting to the shell.
- Reworked Mounted Storage into readable 114-character blocks showing device, filesystem, UUID, label, total/used/free space, usage percentage, full mount path, backing device classification, and connection type.
- Added detection for a partition that occupies virtually an entire physical disk, reported as `Whole drive`; connection detection distinguishes USB, internal NVMe, and internal SATA where the system reports it.
- Wrote `briefs/WOMBAT-WALKER-DISK-HEALTH-BRIEF.md` for a future v2 read-only disk-health utility covering NVMe, SSD, HDD, USB enclosures, and USB flash drives.

### Verification

- Ran `bash -n scripts/wombat-walker.sh`, `python3 -m py_compile scripts/wombat-walker-db.py`, and `git diff --check` for relevant changes.
- Rendered the live mount-list output against the development system after each mount-display change.

### Where we left off

- v1 remains the working day-to-day application; `v1.0-working` remains the original dogfooded baseline at `e7a32c6`.
- The disk-health feature is deliberately deferred to v2. Start with the new disk-health brief after the v2 shared-input/module work is established.

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
