# Wombat Walker — Completed Work

## v1 working baseline — 01 August 2026

- Host explorer, saved metadata search, file/folder management, Wombat Trash, protected-action boundaries, and user preferences completed and dogfooded.
- Docker explorer, scans, search, mount/persistent-data inspection, live editing, lifecycle controls, safety locks, bulk lifecycle actions, and permanent purge receipts completed and dogfooded.
- Every available action was tested in real use, including permanent Docker purge.
- Tested source baseline tagged `v1.0-working` at `e7a32c6`.

## v1 post-baseline polish — 01 August 2026

- Fixed direct Docker launch so `[q]` returns to the host explorer.
- Made mounted-storage information readable: full mount paths, live total/used/free/usage figures, whole-drive versus partition classification, and USB/internal connection type.
- Added Docker Engine storage-category totals (images, container layers, volumes, build cache) alongside Docker Desktop's actual host virtual-disk allocation.
- Added visible per-container progress, elapsed time, and a rolling ETA while calculating writable Docker volume and bind-mount data.
- Added and dogfooded a read-only physical-NVMe health check: direct `--diskcheck` launch, physical-drive picker, explicit sudo fallback, exact command diagnostics, normalized SQLite snapshots, readable local timestamps, saved in-app history, and aligned three-column reports.
- Added the v2 disk-health planning brief; broader SATA/HDD/USB diagnostics and self-tests remain deferred until v2 modularization.
