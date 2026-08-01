# Wombat Walker — v1 Architecture

## Runtime

- `scripts/wombat-walker.sh`: interactive Bash application, host and Docker UI, guarded operations, and preference handling.
- `scripts/wombat-walker-db.py`: private SQLite metadata inventory and FTS-backed host/Docker saved search.
- `scripts/wombat-walker-trash.py`: portable Wombat Trash operations and audit support.
- `scripts/wombat-walker-privileged.sh` and `scripts/wombat-walker-privileged-list.py`: narrowly scoped protected browsing/actions used only after explicit elevation.
- `scripts/install-wombat-walker.sh`: system or user installation.

## Safety boundaries

- Host removal uses Wombat Trash; protected host deletion never uses sudo.
- Docker cleanup and purge are permanent and require explicit typed confirmation.
- Docker bind mounts are preserved by container purge; named volumes/images are removed only when no other container uses them.
- Saved scans record metadata, not file contents. Live paths are rechecked before actions.

## v2 direction

v1 remains the reference implementation. v2 will retain the public command while splitting the Bash application into `ww_`-prefixed modules with shared input, notices, UI, search, files, Trash, Docker, and Utilities layers. See `briefs/WOMBAT-WALKER-V2-REFACTORING-BRIEF.md`.
