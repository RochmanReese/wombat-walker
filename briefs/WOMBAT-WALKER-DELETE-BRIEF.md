# Wombat Walker — deletion and cleanup brief

## Purpose

Build a cautious cleanup system for Wombat Walker. Start with ordinary user-owned host folders,
then reuse the same preview and confirmation model for Docker job folders. The immediate use case is
removing large temporary `*.wav` source files after a completed audiobook archive has been verified,
without touching the ZIP, EPUB, manifest, or other job metadata.

Deletion must be deliberately slower than browsing. A user must always see exactly what will be
affected and must explicitly choose the irreversible action.

## Safety rules

- Walker never uses `sudo` to delete host files. A user can clean only folders they can already
  write to; protected paths remain protected.
- Default host cleanup is **Move to Trash**, not permanent deletion.
- Permanent deletion bypasses Trash only after two typed confirmations.
- Bulk cleanup is current-folder-only in the first release. It must not recurse into descendants.
- Bulk cleanup matches only ordinary regular files. It never follows or deletes symlinks, folders,
  devices, sockets, FIFOs, or the filesystem root.
- User input is an exact file extension, never a raw shell command or unrestricted glob.
- The preview is built from a fresh live directory listing immediately before the action, never from
  a saved Walker scan. Each candidate is rechecked immediately before moving or deleting.
- Every outcome remains visible when the browser redraws, using Walker's persistent bottom notice.

## User-facing workflow: host Walker

Entry point:

```text
[x] Help & utilities → [g] Manage current folder
```

For a folder, add:

```text
[b] Bulk clean up regular files in this folder
```

The initial preview lists every direct regular file in the current folder. It then offers three
selection methods: all previewed files, explicit preview numbers/ranges, or all files of one exact
extension. For the extension selector, accept and normalise only these equivalent forms:

```text
wav
.wav
*.wav
```

Normalise them internally to the exact suffix `.wav`. Reject raw or broad patterns such as `*wav`,
`*`, `*.*`, anything containing `/`, and shell pattern characters other than the optional initial
`*.`. This prevents accidental deletion of `chapter.wav.bak`, `mywav`, or files outside the current
folder.

Show a preview table before any change:

```text
Bulk cleanup preview — current folder only
Extension: .wav

No.  Name                              Logical size       On disk  Last updated
[1]  chapter_000.wav                       274.71MB      274.72MB  2026-07-30 19:24
...

Matches: 22 regular files
Total file data: 8.21GB logical | 8.21GB on disk

[a] Select all previewed files
[n] Select numbered files or ranges
[t] Select all files of one exact extension
[s] Select files whose names start with literal text
[q] Cancel without changes
```

For numbered selection, accept a deliberately small grammar such as:

```text
1,2,3,4,5,6,7,8
1,3,7,9
1-9
1-9, 14, 22-25
```

After parsing, display the selected count and recalculated logical/on-disk totals, then offer:

```text
[1] Move selected files to Trash (recoverable)
[2] Permanently delete selected files
[q] Return to preview
```

Only positive preview numbers, commas, hyphens, and whitespace are valid. Reject malformed input,
reversed ranges, out-of-range numbers, and anything that resembles a shell expression. De-duplicate
repeated selections while preserving the preview order. The user can choose **all** from the preview,
but no action should default to all files automatically.

For prefix selection, accept literal filename text such as `2026` or `Wombat-narrates-book-`. Match
only direct filenames beginning with that exact case-sensitive text. Reject `/` and wildcard syntax
so user input cannot become a path traversal or shell pattern.

Trash confirmation:

```text
Type TRASH to move 22 files to your user Trash:
```

Permanent deletion confirmation:

```text
WARNING: These files bypass Trash and cannot be recovered.
Type DELETE to continue:
Type DELETE 22 to permanently delete these files:
```

Afterwards, print the successful and failed counts plus the on-disk space moved into Trash; explain
that it is not freed until the Trash entry is emptied. Clear current-folder display/size caches, mark any saved scan covering the folder stale, and show a
persistent notice after the browser redraws.

## Coding plan

### Step 1 — Define the reusable candidate and preview engine

**Files:** `scripts/wombat-walker.sh`

Create a small host-side helper that accepts a directory and extension. It must:

1. Verify the target is a directory other than `/` and that the current user has write and execute
   permission on that directory.
2. Normalise and validate the extension input.
3. Use a non-following, one-level live enumeration (`find -P`, `-mindepth 1`, `-maxdepth 1`,
   regular files only) to collect candidates safely, including names with spaces, quotes, or
   newlines.
4. Read each candidate's logical size, allocated blocks, and modification time with `stat`.
5. Render a wide aligned preview and totals.
6. Add a selection parser that accepts comma-separated preview numbers and inclusive ranges. It must
   produce a new list of selected candidate paths and recalculated totals without changing files.

**Success conditions**

- No filesystem change occurs in this step.
- `.wav`, `wav`, and `*.wav` preview the same files.
- `*wav`, `*`, paths containing `/`, directories, and symlinks are rejected or excluded.
- The preview total distinguishes logical from allocated/on-disk size.
- `1,3,7`, `1-9`, and mixed selections return precisely the displayed candidates; duplicate numbers
  are selected once and invalid/reversed/out-of-range ranges are rejected.

**Agent tests**

- `bash -n scripts/wombat-walker.sh` and `git diff --check` pass.
- Use a temporary user-owned test folder containing `.wav`, `.WAV`, `.wav.bak`, a symlink named
  `.wav`, a nested WAV file, and filenames containing spaces. Confirm only direct regular WAV files
  appear.
- Exercise valid and invalid numbered selections, including `1,3,7`, `1-3`, `1-3, 7`, duplicate
  values, reversed ranges, `0`, and an out-of-range number.
- Confirm the code does not use `sudo`, recursive `find`, `eval`, or unquoted glob expansion.

**Human test**

- In a harmless test folder, open `[x] → [b]`, enter `wav`, select a subset by number/range, and
  confirm the selected-file total is correct and cancellation makes no change.

### Step 2 — Implement recoverable bulk Move to Trash

Use the Step 1 candidate list only after the user types `TRASH`. Recheck each candidate remains a
regular non-symlink file in the selected folder, then call `gio trash -- <exact-path>` one file at a
time. Continue after an individual failure and report both counts.

**Success conditions**

- Cancel leaves every file untouched.
- Successful files move to the logged-in user's Trash and are recoverable.
- A failed file is reported without silently deleting anything else.
- Walker never attempts this action in a protected folder or through sudo.
- Successful cleanup marks any saved scan covering the folder stale and leaves a persistent result
  notice after the browser redraws.

**Agent tests**

- Test with a disposable folder of two small WAV files; verify the paths no longer exist and appear
  in the user's Trash.
- Test a non-writable directory and verify the action is refused before confirmation.

**Human test**

- Move a disposable WAV test file to Trash, restore it with the desktop/file-manager Trash view, and
  confirm it returns intact.

### Step 3 — Implement permanent bulk deletion

Expose permanent deletion only from the preview. Require both `DELETE` and `DELETE <displayed-count>`
after the warning. Recheck each path immediately before deletion and delete only the exact regular
file with a quoted `rm -f -- <exact-path>`.

Do not offer an unrestricted “delete all matching everywhere” option. Docker queue-style storage is
an approved exception: it may offer a clearly separate recursive **exact extension** cleanup below
the user-selected folder only, after a full preview, total-space report, and two explicit permanent
deletion confirmations. It must include regular non-symlink files only and must be limited to a
verified read/write named volume or bind mount.

**Success conditions**

- The exact two confirmations are required; any other input cancels.
- Only the displayed direct regular files are removed.
- `.zip`, `.epub`, JSON, logs, `*.wav.bak`, hidden unrelated files, symlinks, and nested WAV files
  survive.
- The final message states that files are permanently deleted and reports expected allocated space
  recovered.

**Agent tests**

- Test with a disposable directory containing mixed extensions, a nested child folder, and a
  symlink. Verify only direct matching regular files are removed.
- Test stale/race handling by removing one previewed file before confirmation; Walker reports it as
  skipped rather than failing dangerously.

**Human test**

- Use a deliberately created disposable WAV test set. Confirm the two prompts are unambiguous and
  that cancelled confirmation makes no change. Then complete the deletion and verify the disk-space
  display changes.

### Step 3a — Add an in-app user Trash manager

Expose separate `[t] Permanently delete files from Wombat Trash` and `[z] Restore files from Wombat
Trash` entries in File cleanup utilities. Both show only the logged-in user's portable Wombat Trash
entries; the split makes recovery and irreversible destruction impossible to confuse, and neither
may use sudo or touch another user's data.

List entries with a preview, logical/on-disk size where available, and original path metadata.
Allow numbered/range selection and an explicit "empty all" preview, then require `DELETE` plus a
second count confirmation before permanently removing selected Trash entries. This is separate from
the direct-file permanent-delete feature: users must be able to free space without leaving Walker,
but they must not confuse it with the recoverable Move to Trash action.

**Success conditions**

- Walker makes clear that moving an item to Wombat Trash does not itself free disk space.
- The manager shows only the current user's Wombat Trash and can be cancelled without modifying it.
- A selected entry is permanently removed only after both confirmations; the final notice states the
  measured or expected disk space freed.
- It refuses malformed metadata, symbolic-link tricks, unavailable Trash locations, and every sudo
  path.

**Human test**

- Move a disposable file to Trash with Walker, open the manager, confirm it appears with its original
  path, cancel once, then delete it with both confirmations and verify available disk space increases.

### Step 4 — Integrate cache and browser feedback

After any successful bulk action, invalidate Walker's current size caches and cached folder totals.
Mark the relevant saved scan as stale or provide a clear “refresh this folder” notice, so a saved
inventory is never presented as current after cleanup.

**Success conditions**

- The file listing redraws without deleted entries.
- Folder totals recalculate or clearly display as stale.
- The confirmation/result message remains visible at the bottom of Walker after redraw.

**Agent tests**

- Start with a saved scan, bulk-remove a test file, and verify the old cached total is not silently
  shown as current.

**Human test**

- Perform a small cleanup and confirm the result notice remains visible long enough to read, then
  use `[v] Update saved scan below this folder` and verify the new total.

### Step 5 — Per-file permanent delete and documentation

Add the same permanent-delete confirmation to the existing regular-file management menu, while
keeping “Move to Trash” first. Update `help.md` and Walker's `[?]` help to explain the extension
rules, Trash vs permanent deletion, no-recursion boundary, no-sudo rule, and cache refresh notice.

**Success conditions**

- Individual and bulk operations use the same confirmation language and safety rules.
- Help is complete enough that a user does not need the repository README to understand deletion.

**Agent tests**

- Review every public menu key and help entry for consistency.
- Run Bash syntax checks and a manual test of both menu paths.

**Human test**

- A non-technical user can explain, before confirming, whether the chosen operation is recoverable
  and exactly which folder/files it will affect.

## Follow-on — Guided copy, move, rename, and folder creation

Add a separate **File management** menu for selected regular files and ordinary folders. It must
offer copy, move, rename, and create-folder actions without turning the normal Walker interface into
an unrestricted privileged file manager; `[!] Open shell in this folder` remains the explicit expert
escape hatch for commands outside Walker's guarded workflow.

### Safety boundary

- Treat `/home`, `/media`, `/mnt`, and other user-writable mounted data locations as normal user
  data, subject to the standard preview and confirmation flow.
- Hard-block Walker copy/move/rename/delete management actions for system paths and their children:
  `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/boot`, `/proc`, `/sys`, `/dev`, `/run`, and
  Docker's own host storage under `/var/lib/docker`. Do not offer a sudo bypass in Walker.
- Do not follow or manage symbolic links. Recheck the source type immediately before action.
- Do not overwrite an existing destination. Show a clear message and require the user to choose a
  new name/path or use their own shell deliberately.
- For a folder move, reject a destination inside the source folder. For copy/move, show source,
  destination, type, and estimated logical/on-disk size before confirmation.
- Copy uses metadata-preserving `cp -a --`; move uses quoted `mv --`. Both run only as the logged-in
  user. A cross-filesystem move must report that it may take longer because the system copies then
  removes the source.
- Protected browsing may remain read-only except for the existing explicitly-confirmed editor flow.
  Walker must never copy sensitive protected files such as `/etc/shadow` or private SSH keys through
  a convenience menu.

### Success conditions

- A user can copy or move a disposable file/folder between two user-owned locations and return to a
  correctly refreshed Walker listing.
- Cancellation, invalid destination, an existing destination, a symlink, or a protected source or
  destination changes nothing.
- A user cannot accidentally move a system file, the root of a mounted filesystem, or a folder into
  itself through Walker.
- `help.md` documents the safety boundary and points users needing unrestricted/admin actions to the
  explicit nested shell.

### Agent and human tests

- Run syntax/diff checks and test copy, same-filesystem move, cross-filesystem move, rename,
  destination collision, nested-folder rejection, symlink refusal, and every protected-path refusal
  using disposable test data.
- A human user copies and moves a harmless folder between a home directory and mounted disk, checks
  the preview before confirming, then verifies that an attempted `/etc` action is clearly refused.

## Docker follow-on (after host Walker is proven)

Docker reuses the candidate/preview/confirmation model but has a different final adapter:

- Docker cleanup is permanent because moving multi-GB temporary job data to host Trash wastes disk
  space.
- Start with an explicit shortcut: `[w] Purge temporary WAV files in this folder`.
- Also offer the general exact-extension cleanup menu later.
- Limit the first version to the active container folder, no recursion, regular files only.
- Before confirmation, show the container, current container path, whether it belongs to a writable
  layer/named volume/bind mount, matching count, and logical/on-disk totals.
- Warn that a completed `audiobook.zip` should be verified and safely downloaded before source WAVs
  are purged. Do not require one hard-coded archive filename; applications differ.
- Reuse the two permanent-delete confirmations and then refresh the live folder listing, invalidate
  cached Docker totals, and mark the relevant Docker scan stale.

## Explicit non-goals for this release

- Recursive deletion or wildcard deletion across a disk/container.
- Deleting protected host files via sudo.
- Deleting Docker images, containers, named volumes, bind-mount roots, or Docker system data.
- Automatic cleanup based only on age or file extension.
- Assuming an archive is valid or downloaded without user confirmation.
