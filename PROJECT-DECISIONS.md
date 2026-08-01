# Wombat Walker — Project Decisions

## 01 August 2026 — Freeze v1 before refactoring

The dogfooded v1 implementation is the behavioural baseline. It is tagged `v1.0-working` at `e7a32c6`; v2 must be created from that reference and migrated incrementally.

## 01 August 2026 — Docker safety model

Stopped containers are locked by default. They must be explicitly unlocked before remove or purge; running containers must be stopped first. Container purge preserves bind mounts and reports every Docker resource it removed or preserved.

## 01 August 2026 — v2 naming and interaction rules

Every v2 function uses a `ww_` prefix. Walker-owned prompts will support global `#` commands through one shared input layer, while editor input and exact destructive confirmations remain untouched.
