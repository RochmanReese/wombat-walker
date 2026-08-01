# Wombat Walker — End of Session Checklist

Complete these steps before ending a Walker session.

1. Update `README.md` when user-facing behaviour changes.
2. Update `docs/PROJECT-ROADMAP.md`: mark finished work and identify the next safe task.
3. Update `PROJECT-COMPLETED.md` for completed features or verified milestones.
4. Update `PROJECT-ARCHITECTURE.md` if runtime structure, data flow, or safety boundaries changed.
5. Update `PROJECT-DECISIONS.md` for durable product or safety decisions.
6. Add a new entry at the top of `PROJECT-SESSIONLOG.md` with what changed, verification, handoff, and cautions.
7. Run proportionate checks: at minimum `bash -n scripts/wombat-walker.sh`, `python3 -m py_compile scripts/wombat-walker-db.py` when Python changed, and `git diff --check`.
8. Review `git status --short`; never add the user-owned `pics/` assets unless explicitly asked.
9. Commit the intended tracked files with a descriptive message and push `master` when the user authorizes it.
10. For a tested release baseline, create and push an annotated tag before beginning any refactor branch or v2 copy.

New session-log entries go at the top. Never delete earlier entries.
