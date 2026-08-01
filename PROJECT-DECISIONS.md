# Wombat Walker — Project Decisions

## 01 August 2026 — Freeze v1 before refactoring

The dogfooded v1 implementation is the behavioural baseline. It is tagged `v1.0-working` at `e7a32c6`; v2 must be created from that reference and migrated incrementally.

## 01 August 2026 — Docker safety model

Stopped containers are locked by default. They must be explicitly unlocked before remove or purge; running containers must be stopped first. Container purge preserves bind mounts and reports every Docker resource it removed or preserved.

## 01 August 2026 — v2 naming and interaction rules

Every v2 function uses a `ww_` prefix. Walker-owned prompts will support global `#` commands through one shared input layer, while editor input and exact destructive confirmations remain untouched.

## 01 August 2026 — NVMe health safety and presentation

Physical-NVMe health was brought forward into v1 for drive-migration decisions. It uses only the
read-only `nvme smart-log` diagnostic, saves normalized snapshots in Walker's private SQLite
database, and renders live and saved reports in aligned three-column layouts. Sudo is requested
only after a normal-user attempt fails and the user explicitly approves the retry; broader
SATA/HDD/USB diagnostics and all self-tests remain v2 work.
