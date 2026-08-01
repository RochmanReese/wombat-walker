# Wombat Walker v2 — Refactoring and Global Command Brief

## Purpose

Wombat Walker v1 is the working dogfooding release. It provides a useful terminal filesystem
browser, saved metadata search, cleanup tools, file management, Docker inspection, editing, and
Wombat Trash. Its Bash implementation has grown organically and now contains repeated menus,
input handling, search dispatch, validation, notices, and file-management paths.

This brief defines the v2 refactoring project. v2 must preserve the useful v1 behaviour while
making the implementation modular, discoverable, testable, and easier to extend.

## Why we are doing this

- The current Bash entry point is more than 2,700 lines and is difficult to reason about as one file.
- Similar functions and menus have been implemented in multiple places.
- A bug fix can correct one path while leaving another copy inconsistent.
- Interactive input is repeated instead of being handled by one shared command layer.
- Search, Utilities, notices, folder selection, and file management need to work consistently from
  every screen.
- A predictable function namespace will make later CodeWombat repository scanning and maintenance
  more reliable.

v2 is an internal refactoring release first. It should not change the public command name or
deliberately alter the safety model while code is being moved.

## v1 preservation strategy

Before v2 refactoring begins:

1. Finish the current Walker dogfooding and settle the v1 UI behaviour.
2. Commit the complete working state.
3. Tag the exact commit as the v1 working baseline, for example `v1.0-working`.
4. Preserve a v1 folder as a directly runnable reference copy.
5. Create v2 from that exact baseline.

The v1 copy is not to be refactored casually. Every v2 change must remain comparable with v1 and
must be recoverable by returning to the tagged commit or preserved folder.

## Ultimate goal

The ultimate goal is a dependable, extensible terminal workspace for understanding and managing a
real Linux filesystem. Users should be able to browse, search, refine results, inspect Docker,
edit permitted files, and perform guarded file operations from wherever they are without losing
context or repeating navigation.

The implementation should have one canonical function for each major behaviour, one shared input
layer, one persistent-notice mechanism, one search flow, and one Utilities flow. New features must
extend those shared paths instead of creating another local copy.

## Global `#` shortcuts

Every Walker single-letter action will have a corresponding global `#` shortcut. The shortcut is
recognized at Walker-owned prompts regardless of the current Walker screen:

```text
#m  Manual path
#s  Search
#x  Utilities
#h  Help
#q  Return or quit the current Walker screen
```

The exact public letter set may grow, but every shortcut must have one named implementation and a
documented meaning. A shortcut must preserve the current folder and relevant context. For example,
`#x` opens Utilities for the folder currently in context, including when the user reached that
folder through search results.

Global shortcuts must not intercept external editor input, nested shell input, passwords, or exact
safety confirmations such as `TRASH`, `DELETE`, `EDIT`, `COPY`, `MOVE`, `RENAME`, or `CREATE`.
The input layer should reserve `#` only when it appears as the command prefix; `##` may represent a
literal leading hash where a literal search term is needed.

## Function naming rule

Every function introduced or moved into v2 must use the `ww_` prefix. This is mandatory, not a
style preference. It avoids collisions between sourced modules and makes automated CodeWombat
scanning, indexing, and maintenance straightforward.

Examples:

```text
search_utilities_menu       → ww_search_utilities_menu
file_management_menu        → ww_file_management_menu
file_action_menu            → ww_file_action_menu
walker_help_screen          → ww_walker_help_screen
```

Variables may be migrated to a consistent `WW_` convention in a later pass, but functions must
use `ww_` from the beginning of v2. No unprefixed project functions should remain after a module is
refactored.

## Proposed v2 project layout

```text
scripts/
  wombat-walker.sh             # public entry point, startup, arguments, main loop
  walker-input.sh              # ww_read, # shortcut parsing, cancellation
  walker-ui.sh                 # rendering, tables, pagination, notices, help
  walker-search.sh             # one search flow, scopes, filters, result actions
  walker-files.sh              # view, edit, copy, move, rename, folder management
  walker-trash.sh              # Wombat Trash, cleanup previews, confirmations
  walker-docker.sh             # Docker workspace, scans, search, guarded actions
  walker-utilities.sh          # shared Utilities menu and dispatch
  wombat-walker-db.py          # SQLite metadata/search backend
  wombat-walker-trash.py       # portable Trash backend
```

The public `wombat-walker.sh` entry point sources the internal modules using paths derived from its
own `SCRIPT_DIR`; it must not depend on the caller's working directory. The installer must copy all
required v2 modules and retain the same public command interface.

## Refactoring order

### Phase 1 — Freeze and test v1

- Complete current UI dogfooding.
- Record the v1 tag and preserve the working folder.
- Capture smoke tests for browsing, search, result refinement, folder selection, Utilities,
  management actions, Trash, Docker, and editing.

### Phase 2 — Establish the shared input and notice layer

- Add `ww_read` or equivalent input wrapper.
- Add global `#` shortcut dispatch.
- Centralize cancellation and common validation.
- Centralize the persistent bottom notice so errors always appear immediately above navigation.
- Keep editor, shell, password, and safety-confirmation input outside the global wrapper.

### Phase 3 — Extract UI and shared rendering

- Move table rendering, pagination, order labels, folder choosers, and help into `walker-ui.sh`.
- Ensure browser lists, search folder lists, and search results share rendering conventions.
- Preserve the rule that notices appear below file/folder content and immediately above navigation.

### Phase 4 — Extract the single search implementation

- Move all search scope selection, automatic selected-folder refresh, manual folder paths, word
  search, multi-word AND matching, size refinement, ordering, pagination, and result actions into
  `walker-search.sh`.
- Remove duplicated normal/direct/combined dispatch where a parameterized canonical function can be
  used.
- Keep `[g] Manage search result`, `[o]` open/view/edit, `[f]` refine, `[r]` new words, and `[x]`
  Utilities available without losing the current folder or search context.

### Phase 5 — Extract file, Trash, Docker, and Utilities modules

- Move file management and editing into `walker-files.sh`.
- Move cleanup and Wombat Trash flows into `walker-trash.sh`.
- Move Docker browsing, scans, search, and safety checks into `walker-docker.sh`.
- Implement one `ww_utilities_menu` used by the main browser and search-result context.

### Phase 6 — Remove duplicate implementations

- Search for remaining unprefixed functions and repeated menu logic.
- Replace local copies with calls to the canonical `ww_` function.
- Keep safety checks close to the shared operation, not repeated inconsistently by callers.
- Add shell syntax, fixture, and interactive smoke tests for every extracted module.

## Safety and compatibility requirements

- v2 must remain unprivileged by default and preserve the existing explicit sudo boundaries.
- Walker must never silently overwrite, delete protected files, follow symlinks, or turn a cached
  search result into an unchecked live action.
- All selected paths must be checked live before opening, editing, copying, moving, renaming, or
  moving to Trash.
- Existing v1 command-line flags and the public `wombat-walker` command must continue to work.
- Every refactoring commit must pass `bash -n`, `git diff --check`, and relevant fixture tests.
- Changes should be small enough that v1 can be used as the comparison oracle when behaviour is
  uncertain.

## Completion definition

v2 is complete when the modular implementation provides the same or better v1 behaviour, every
project function uses the `ww_` prefix, global `#` shortcuts work consistently at Walker prompts,
search and Utilities are canonical shared flows, notices are reliably visible at the bottom, and
the public installer and command interface remain stable.
