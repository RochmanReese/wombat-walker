# Wombat Walker — Session Log

New entries go at the top. Each entry records the working state, verification, next handoff, and any cautions.

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
