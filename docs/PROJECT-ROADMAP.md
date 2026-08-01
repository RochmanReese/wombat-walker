# Wombat Walker — Project Roadmap

## ✅ Phase 1 — v1 dogfooding and feature completion

**Status: complete — 01 August 2026**

- Host filesystem browsing, path entry, sorting, paging, hidden-item control, owner display, shell access, and cautious file/folder management.
- Saved host search with scope selection, refresh, multi-word matching, sorting, size refinement, pagination, retry, and result actions.
- Wombat Trash and guarded host cleanup.
- Docker inventory, live browsing, saved metadata scans/search, mount inspection, persistent-data calculation, live file editing, lifecycle management, safety locks, bulk start/stop, and permanent purge receipts.
- Post-baseline v1 polish: direct Docker launch returns to the host explorer; mount inspection now shows full source/path, live capacity, usage, whole-drive versus partition status, and connection type.
- All user-facing actions dogfooded successfully, including Docker purge.
- Tested code baseline: `v1.0-working` at commit `e7a32c6`.

## 🔜 Phase 2 — v2 modular refactor

**Status: planned. Do not modify v1 as part of this phase.**

1. Create v2 from the `v1.0-working` baseline while retaining v1 as a runnable reference.
2. Establish a shared `ww_`-prefixed input/notice layer and global `#` shortcuts.
3. Extract common UI, rendering, pagination, and picker code.
4. Consolidate host and Docker search around canonical shared flows.
5. Extract files, Trash, Docker, and Utilities into focused modules.
6. Remove duplicated menu, validation, and lifecycle code only after parity checks against v1.
7. Add fixture and interactive smoke coverage for every extracted module.
8. After the shared v2 input/UI layers are established, implement the read-only disk-health utility described in [WOMBAT-WALKER-DISK-HEALTH-BRIEF.md](../briefs/WOMBAT-WALKER-DISK-HEALTH-BRIEF.md).

The authoritative v2 plan is [WOMBAT-WALKER-V2-REFACTORING-BRIEF.md](../briefs/WOMBAT-WALKER-V2-REFACTORING-BRIEF.md).

## 🔭 Later work

- Continue real-world dogfooding of v1 only for bug reports that must be backported before v2 starts.
- Improve automated fixtures for Docker storage and permission edge cases.
- Consider CodeWombat indexing once v2's `ww_` function namespace and module boundaries are in place.
