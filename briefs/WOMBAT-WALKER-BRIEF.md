# Wombat Walker and Wombat Walker Little — Build Brief

## Objective

Extract the growing local filesystem browser from `wombat-backup.sh` into a useful standalone,
normal-user server exploration tool called **Wombat Walker**. Later provide a separate restricted
selector called **Wombat Walker Little** for Wombat Backups and other applications.

Wombat Backups must call Wombat Walker Little when it needs a source or local destination path.
The future GUI must never invoke Walker's internal privileged worker.

This brief does not add `locate`/`plocate` integration. It may be considered later as an optional
path-search accelerator, but its index is not a live source of file size or modification data.

## Clear product definitions

| Tool | Command | Privilege | What it does | What it must not do |
|---|---|---|---|---|
| Wombat Walker | `wombat-walker` | Current user by default | Main everyday browser. It shows only locations the user can access, uses a private user cache, and explicitly requests sudo only for a protected scan or edit action. | Run permanently as root, silently elevate, make destructive filesystem changes, or run arbitrary commands from menu input. |
| Wombat Walker Little | `wombat-walker-little` | Current user only | Restricted read-only browser/selector for Wombat Backups and later other apps. | Elevate privileges, edit/delete/move/rename files, or silently inspect inaccessible paths. |
| Walker privileged worker | Internal only; invoked by Walker through `sudo` | Root for one requested operation | Performs a protected deep scan, queries the root-owned scan cache through fixed actions, or performs an approved `sudoedit` route. | Provide a general root shell, accept arbitrary command text, or be called by the GUI. |

Both tools are read-only while browsing. Wombat Walker's editing operation is a separate,
confirmed action after a file has been selected.

## Architecture

Use one shared engine and two small entry points. Do not duplicate the browser implementation.

```text
scripts/wombat-walker-core.sh       # listing, navigation, sorting, rendering, selection protocol
scripts/wombat-walker.sh             # normal-user main entry point during development
scripts/wombat-walker-little.sh      # restricted selector entry point during development
scripts/wombat-walker-privileged.sh  # narrow root worker; never a general interactive shell
```

The core must be able to run in these modes:

| Mode | Purpose | Output contract |
|---|---|---|
| Browse | Everyday terminal exploration. | Human-readable UI on the terminal. |
| Select file | Choose one accessible regular file. | Canonical selected path only; cancellation is distinct. |
| Select folder | Choose one accessible directory. | Canonical selected path only; cancellation is distinct. |
| Select either | Choose a regular file or directory. | Canonical selected path only; cancellation is distinct. |

For selection mode, keep UI output separate from the result. The recommended contract is a
private temporary result file supplied by the caller; the core writes the selected canonical path
only after success. Cancellation returns exit status `2`; operational failure returns non-zero
other than `2`. This avoids trying to parse terminal menus from stdout and is suitable for the
future GUI backend.

## Common browser behaviour

The shared engine must support:

- folder navigation, `up`, current-folder selection, manual path entry, and cancel;
- configurable entries per page, default `30`, safe range `1`–`200`;
- visible entries by default, with an explicit hidden-file toggle rather than hidden paths being
  silently inaccessible;
- columns for name, human-readable size, and last updated timestamp;
- sort choices: alphabetical, largest first, smallest first, most recently updated first;
- separate treatment of a regular file's logical size and a directory's allocated disk use;
- an optional logical total for the currently viewed folder tree;
- label folder-tree sums as **logical file-size totals**. They can exceed physical capacity because
  sparse files, hard links, and bind mounts can make a file-size sum larger than unique allocated
  blocks. Show instant unique filesystem capacity/use/free space from `df` separately;
- `--filesize on|off`, default `on`. `off` performs no size scan and must reject size-based sort;
- no symlink traversal while scanning. Display a symlink distinctly and resolve/check a selected
  path immediately before returning it;
- careful quoting for whitespace and unusual paths. Do not use line-delimited parsing for internal
  filenames; use NUL-delimited data where practical.

The existing in-progress browser behaviours in `wombat-backup.sh` are the starting point. Move
them only after the standalone engine has equivalent automated and human-tested behaviour.

## Wombat Walker Little requirements

Suggested interface:

```text
wombat-walker-little [start_path]
  [--select file|folder|either]
  [--result-file <private-path>]
  [--items-per-page <1-200>]
  [--sort alphabetical|largest|smallest|updated]
  [--filesize on|off]
  [--hidden on|off]
```

Defaults:

- `start_path`: current directory for standalone use; caller supplies a deliberate start directory
  for backup selection;
- `--select`: absent, so normal browse mode;
- `--hidden off`;
- `--items-per-page 30`, `--sort alphabetical`, `--filesize on`.

The Little entry point must never invoke `sudo`, even if a path cannot be read. It explains that
the path is protected and offers navigation elsewhere.

## Wombat Walker privileged actions

Wombat Walker itself starts without sudo:

```text
wombat-walker [start_path]
  [--items-per-page <1-200>]
  [--sort alphabetical|largest|smallest|updated]
  [--filesize on|off]
  [--hidden on|off]                 # default off
  [--here]                           # start in the caller's current directory
```

Protected actions explicitly ask for sudo when selected. Examples:

```text
wombat-walker --deep-scan filesystem       # asks sudo only if protected paths are in scope
wombat-walker --deep-scan filesystem --sudo # explicitly use the isolated root scan worker
wombat-walker --edit /etc/example.conf     # uses sudoedit after EDIT confirmation
```

The root worker uses a controlled system `PATH` and must not accept a shell command, command
fragment, or untrusted editor argument from a menu field. A normal Walker session must never be
silently replaced by a root shell.

Walker must never keep a long-lived elevated browser process merely because the ordinary browser
remains open. For protected directory listing, deep scans, and edits, launch a narrow privileged
worker for the requested action, return its validated result to normal Walker, then let that worker
exit. `sudoedit` follows the same model for a selected file. The normal Walker process therefore
remains unprivileged even when left open all day.

Standard sudo timestamp behaviour is outside Walker's process lifetime: the first protected
action may request a password, and later approved actions in the same terminal may reuse sudo's
normal timeout. Do **not** automatically run `sudo -K` when a Walker action ends, because that
would unexpectedly clear the user's wider sudo cache. Offer an explicit “forget sudo now” action
later for users who want it. A user who deliberately launches Walker from a root shell already
has root authority; Walker should display `Access mode: root` but cannot revoke its parent shell.

After a regular file is selected, present a separate action menu:

```text
[1] View safely
[2] Edit with Nano
[3] Edit with Vim
[q] Return without changes
```

Before an edit, print the canonical path and require the exact confirmation word `EDIT`.
Prefer `sudoedit` with a fixed approved editor path over running a whole arbitrary editor process
as root. Do not add delete, rename, move, ownership, permission, or recursive actions in this
feature.

For production installation, install the **privileged worker** as a root-owned executable in
`/usr/local/lib/wombat-walker/` with non-writable parent directories. The ordinary Walker can
remain user-installable. A user-writable Git checkout is acceptable only for development, not as
the permanent sudo worker.

## Installation model

Provide one installer with two explicit modes, rather than two unrelated installers:

```text
scripts/install-wombat-walker.sh --user
sudo scripts/install-wombat-walker.sh --system
```

### `--user` — no sudo required

Install only the ordinary, read-only Walker for the current account:

```text
~/.local/bin/wombat-walker
~/.local/lib/wombat-walker/
~/.local/state/wombat-walker/scans.db
```

The installer must not create a sudoers rule, root worker, `/var/lib` database, or system-wide
command. It prints clear PATH instructions when `~/.local/bin` is absent from the user's PATH.
This mode is safe and useful for any non-sudo user, but it can only inspect paths that account can
read and cannot edit protected files.

### `--system` — explicitly run through sudo

Install shared ordinary components and the privileged worker:

```text
/usr/local/bin/wombat-walker
/usr/local/lib/wombat-walker/wombat-walker.sh
/usr/local/lib/wombat-walker/wombat-walker-db.py
/usr/local/lib/wombat-walker/wombat-walker-privileged.sh
/var/lib/wombat-walker/scans.db
```

The privileged worker, database directory, and installed supporting code must be owned by
`root:root`; ordinary users must not be able to modify them. The system installer may be run by a
normal account such as `wombat` that has sudo permission; a root login is not required.

The system installer must ask which authorised users/groups may request privileged Walker actions.
Start with a conservative policy: only users already authorised for sudo. The sudoers rule must
allow only the exact root-owned privileged-worker command and its validated fixed actions—not a
shell, wildcard command, arbitrary editor, or arbitrary script path. Do not use `NOPASSWD` by
default.

After system installation, every user runs the same ordinary command:

```text
wombat-walker --here
```

Non-sudo users receive the normal explorer experience. Authorised users are prompted only when
they deliberately select a protected action. The future installer may add `--uninstall`, but it
must never remove a user installation or scan cache without explicitly showing its target and
asking for confirmation.

## Scan cache and SQLite design

### Decision

Use SQLite as an **optional cache and scan-history store**, not as the live filesystem truth.
It can make repeat views fast and record when data was last measured, but every selected path
must still be checked with `lstat` before it is returned or edited.

Keep normal-user and admin caches separate:

```text
~/.local/state/wombat-walker/scans.db        # ordinary Walker; mode 0600
~/.local/state/wombat-walker-little/scans.db # Walker Little; mode 0600
/var/lib/wombat-walker/scans.db              # privileged worker; root:root, mode 0600
```

Never put file contents, credentials, or editor buffers in either database. Paths and metadata
are sensitive enough to keep these databases private and out of Git.

### Deep scan scopes

A deep scan means walking **every accessible regular file** below the selected scan root and
recording metadata for every entry; it does not mean looking only at the root directory's
timestamp.

| Scan scope | What is scanned | Intended use |
|---|---|---|
| `current` | The folder currently being browsed and all of its descendants. | An exact current total for one project, website, or backup source. |
| `filesystem` | The whole mounted filesystem that contains the current folder, without crossing onto another mount. | A complete picture of one local disk or USB drive. |
| `all-local` | Every selected persistent local filesystem, each scanned separately. | Wombat Walker's full-server inventory. |

`all-local` must exclude pseudo and runtime filesystems by default, including `/proc`, `/sys`,
`/dev`, `tmpfs`, `overlay`, `cgroup`, and other ephemeral mounts. Network filesystems and external
drives are scanned only when deliberately selected. A filesystem boundary is never crossed
silently, so an aggregate can always state which disk it represents.

Normal Walker can deep-scan only paths that its user can read. Any permission failure is recorded
in `scan_errors`, makes the scan status `incomplete`, and prevents its total being described as a
complete disk total. A selected protected scan invokes the root worker through sudo; it writes to
the separate root-owned cache and returns only the requested status/result to Walker.

Initial CLI interface:

```text
wombat-walker [start-path] --deep-scan current|filesystem [--sudo]
```

`current` scans the supplied/start directory; `filesystem` resolves its containing mount point.
Without `--sudo`, the ordinary private database records every accessible entry and reports an
`incomplete` result if permissions prevent a full inventory. `--sudo` is an explicit privileged
action: it starts the narrow worker for just that scan, writes only to the root-owned database,
and exits when finished. It does not elevate the ordinary Walker process or its parent terminal.

The measured baseline on the development machine was a scan of every readable regular file on the
main 457 GB filesystem: about 10.4 seconds, with protected paths skipped because it was not run
as root. Treat this only as a baseline; elapsed time depends on file count, storage speed, cache
warmth, and permissions.

### How a new session uses a previous deep scan

1. The browser can immediately show a cached total labelled, for example,
   `Cached full-filesystem scan: 2026-07-31 10:15, incomplete`.
2. A user can request a live `current`, `filesystem`, or `all-local` deep scan when exact current
   data matters.
3. The live scan walks every file in its scope, updates the SQLite rows, records errors, and
   writes a new `scan_runs` row.

Do not infer that a complete subtree is unchanged merely because its directory timestamp is
unchanged. A file-content modification normally changes that file's metadata but not its parent
directory's timestamp on ext4 and similar filesystems. Without a continuously running watcher,
an honest current result requires visiting each file's metadata again.

### Cached inventories and targeted refresh

The SQLite database is the everyday discovery index. Once a deep scan has completed, ordinary
browsing, cached size views, sorting, and search must read that database without walking the disk
again. A scan is a deliberate update to the index, not a required action every time Walker starts.

Each saved root must have a user-selected policy:

| Policy | Intended storage | Default behaviour |
|---|---|---|
| `active` | A server disk or project tree changed frequently. | Show its saved inventory immediately; a future user-configured refresh reminder may be offered. |
| `archive` | A mostly static USB/HDD archive, media collection, or cold backup. | Never rescan automatically. Keep its prior inventory searchable until the user explicitly says something changed. |
| `manual` | Any root where the user wants complete control. | Never rescan automatically; refresh only through an explicit command/action. |

The initial default is `manual`, not automatic scanning. Display every root's last scan time and
status clearly so cached data is never confused with live filesystem data.

For archive and manual roots, provide a browser action:

```text
[a] I changed this folder — refresh this folder only
```

The equivalent CLI command is a current-scope scan rooted at that folder:

```text
wombat-walker /mnt/archive/photos --deep-scan current
```

A targeted refresh walks only the selected folder and descendants. It must add new entries there,
update changed metadata there, and remove cached records for deleted paths there—never records
outside that subtree. It must recalculate the selected folder total and invalidate or recompute
ancestor totals, so a whole-disk total is never presented as current when only selected folders
were refreshed. This is the normal workflow when the user knows they changed only `photos`,
`ebooks`, `audiobooks`, or `repos` on a large archival disk.

An optional future structure-only check may inspect directory metadata to report likely
additions/removals, but it must be labelled **not a full verification; content-only edits can be
missed**. A fully verified scan still needs to inspect metadata for every in-scope file.

`locate`/`plocate` is not a substitute for this process. Its `updatedb` job indexes paths under
configured locations for fast name search; it may be stale or excluded from locations, and it does
not supply authoritative current recursive logical/allocated totals or prove that files are
unchanged.

### Cached Walker search

After a completed deep scan, Wombat Walker must provide an easy interactive search over its own
SQLite metadata. This is the product's fast file finder; it does not depend on `locate`.

Suggested interface:

```text
wombat-walker --search <words>
wombat-walker --search <words> --root <scanned-root>
wombat-walker --search <words> --sudo              # search the separate root-owned cache
```

Also provide an in-browser `[s] Search scanned files` action. Ordinary multi-word search requires
every word in the basename; a query containing `/` searches the full path. Search is
case-insensitive by default and returns numbered results with path, type,
human-readable size, last updated time, and the source scan's timestamp/status. Results can be
filtered by file/folder, minimum/maximum size, and most-recently-updated order in a later UI pass.

Selecting a result must run `lstat` on the live path before opening its parent folder, viewing it,
or offering an edit. If the path has moved, been deleted, changed type, or is now inaccessible,
say so clearly and offer a new live/deep scan; never treat stale cache data as a live result.

The initial search indexes **metadata only**: paths, names, types, sizes, and timestamps. Do not
search file contents in this feature. Content indexing has separate privacy, access-control,
storage, and performance requirements and requires its own future brief.

### Proposed schema

| Table | Important fields | Purpose |
|---|---|---|
| `scan_roots` | `id`, `root_path`, `device_id`, `privilege_context`, `refresh_policy`, `last_full_scan_at`, `last_partial_scan_at`, `last_status`, `totals_stale` | One configured or previously scanned root. `refresh_policy` is `active`, `archive`, or `manual`; `privilege_context` distinguishes normal-user from admin results. |
| `scan_runs` | `id`, `root_id`, `started_at`, `finished_at`, `scope`, `status`, `entry_count`, `error_count`, `scanner_version` | Audit/history of each full or targeted scan, including incomplete scans. |
| `path_entries` | `root_id`, `path`, `device_id`, `inode`, `entry_type`, `logical_size_bytes`, `allocated_size_bytes`, `mtime_ns`, `ctime_ns`, `last_seen_scan_id` | Cached metadata per path; unique `(root_id, path)`. |
| `directory_totals` | `root_id`, `path`, `logical_total_bytes`, `allocated_total_bytes`, `newest_mtime_ns`, `calculated_scan_id` | Cached subtree totals for fast folder displays. |
| `scan_errors` | `scan_id`, `path`, `operation`, `error_text` | Permission or I/O failures. A scan with errors must be labelled incomplete. |
| `path_search` (FTS5) | `path`, `basename`, `root_id`, `entry_id` | SQLite full-text index over cached path/name metadata for fast interactive search. It contains no file contents. |

At the end of a successful scan, remove or mark entries not seen in that scan. Never silently
reuse a total from a scan whose status was incomplete without displaying its timestamp/status.

### Docker cache and storage tables

Docker discovery and scans belong in the **same private Walker database file**, but in their own
tables. Do not put Docker container paths into `path_entries`, and do not mix Docker scans with
normal-user or root filesystem scan runs: a Docker path such as `/data/book.m4b` has meaning only
alongside its container and mount identity.

| Table | Important fields | Purpose |
|---|---|---|
| `docker_containers` | `id`, `container_id`, `name`, `image`, `status`, `created_at`, `last_seen_at`, `writable_size_bytes`, `virtual_size_bytes` | Live Docker identity and display metadata. `container_id` is the stable key; name is only a readable label and can change on recreation. |
| `docker_mounts` | `id`, `container_id`, `mount_type`, `volume_name`, `host_source`, `container_destination`, `read_write`, `safety_state`, `last_seen_at` | Each bind mount, named volume, tmpfs, or other mount. `safety_state` is initially `unreviewed`; only an explicitly user-approved read/write data mount can later offer cleanup actions. |
| `docker_scan_runs` | `id`, `container_id`, `mount_id`, `scope`, `started_at`, `finished_at`, `status`, `entry_count`, `error_count` | History of a read-only live-container or mounted-data scan. A scan is stale when its container ID, mount mapping, or target path is no longer live. |
| `docker_path_entries` | `scan_id`, `container_id`, `mount_id` nullable, `container_path`, `relative_path`, `entry_type`, `logical_size_bytes`, `allocated_size_bytes`, `mtime_ns` | Cached Docker file/folder metadata. Keep container filesystem paths distinct from paths belonging to a persistent mount. |
| `docker_path_search` (FTS5) | `entry_id`, `container_name`, `volume_name`, `container_path`, `basename` | Fast metadata-only Docker search. It contains no file contents or environment values. |
| `docker_resource_inventory` | `id`, `resource_type`, `resource_id`, `name`, `size_bytes`, `status`, `labels_json`, `first_seen_at`, `last_seen_at`, `last_inventory_at` | Current/recent Docker resources outside a container-path scan: stopped containers, images, volumes, networks, and build-cache summary rows. It supports a review-first cleanup report. |
| `docker_cleanup_audit` | `id`, `mount_id`, `container_id`, `path`, `action`, `logical_size_bytes`, `performed_at`, `result`, `error_text` | Later record of explicit copy-out, recoverable volume-trash, or permanent-purge actions. It is an audit trail, not a restore mechanism. |
| `file_operations_audit` | `id`, `source_path`, `destination_path` nullable, `action`, `entry_type`, `logical_size_bytes`, `item_count`, `performed_at`, `result`, `error_text` | Audit history for ordinary host copy, move, Trash, and later permanent-purge operations. It contains metadata only, never file contents. |

The ordinary Docker workspace must remain live/read-only until these tables and their safety model
exist. Never infer that a read/write mount contains disposable media: databases, configuration,
and user data can all be writable. A user must explicitly mark a mount as managed data before a
future copy-out or purge operation is enabled.

### Why timestamps alone cannot safely skip a deep scan

On normal Linux filesystems such as ext4, changing a file's contents usually changes the file's
mtime/ctime but **does not change the parent directory's mtime**. Therefore this is incorrect:

```text
"The root folder timestamp is unchanged, so nothing inside changed."
```

It can miss modified files and report a stale backup-size estimate. Checking every directory
timestamp has the same problem for direct child file-content changes.

There are only three honest approaches:

1. **Live scan when an exact current total is requested** — correct, but may take time.
2. **Show cached values marked “scanned at <time>”** — fast, but explicitly not live.
3. **Run a persistent filesystem watcher service** — records events between sessions, but is a
   separate operational feature. It can miss events while stopped or after queue overflow and
   still needs periodic full validation scans.

The first implementation should use options 1 and 2. Do not claim that SQLite alone eliminates
rescans. A future optional `wombat-walker-indexer.service` can use `inotify`/`fanotify` to mark
cached paths dirty; it is out of scope until the core Walker is stable.

## Implementation steps

### Step 1 — Extract and stabilise the read-only engine

Move the browser from `wombat-backup.sh` into `wombat-walker-core.sh`. Add Walker Little
entry point and preserve all currently working navigation, pagination, size, total, and cancel
behaviour.

**Agent success conditions**

- The ordinary tool never executes `sudo`, an editor, or a mutating filesystem command.
- `--select file`, `folder`, and `either` return a canonical path through the result-file contract.
- Cancellation returns status `2` and leaves no result file content.
- `wombat-backup.sh` uses the new selector for its source and local destination paths.
- `bash -n` passes for every changed shell script.

**Human confirmation test**

- Browse a mounted USB drive, navigate three levels, page forward/backward, select a folder for a
  backup, then repeat and cancel. Confirm the backup CLI gets only the selected path and no file
  operation occurs during browsing.

### Step 2 — Complete display controls and truthful totals

Implement entries-per-page, ordering, hidden toggle, columns, and current-folder totals. Ensure
size-based ordering is unavailable when `--filesize off`.

**Agent success conditions**

- Test each order with fixture files having known sizes and mtimes.
- Test 1, 30, and 200 entries per page; reject 0, negative, non-numeric, and over-limit values.
- Test a directory containing spaces, a symlink, hidden file, unreadable child, and more than one
  page of entries.
- A permission error is visibly represented as unavailable/incomplete, never as a trustworthy 0.

**Human confirmation test**

- Browse a known project directory and confirm alphabetical, largest, smallest, and newest order
  are understandable and that the folder total matches an independently checked `du` estimate.

### Step 3 — Add safe SQLite caching and history

Create a small Python SQLite helper using parameterised statements and the schema above. Add
`--cache live|cached|off` with `live` as the initial default. `cached` must display the scan date
and scan status beside every cached aggregate.

**Agent success conditions**

- Temporary-database tests cover schema creation, private permissions, successful scans, partial
  scans, deleted entries, cache expiry/status display, and normal/admin database separation.
- No cache result is displayed as live if it came from a previous scan.
- Database files, generated scan data, and private paths are ignored by Git.

**Human confirmation test**

- Deep-scan a harmless test tree, change a file's contents without changing its parent directory,
  then compare `--cache cached` with `--cache live`. Confirm the cached result is visibly dated
  and the live result changes.

### Step 3a — Add fast metadata search from completed scans

Create the SQLite FTS5 path/name index and expose it through both `--search` and the browser's
`[s]` search action. Search must use parameterised SQLite queries; never build SQL from search
text.

**Agent success conditions**

- Scan a fixture tree and search partial names, path segments, mixed case, directories, and files.
- Assert returned results show the scan timestamp/status and contain no file contents.
- Delete or rename a fixture after scanning; selecting its cached result detects the stale path by
  live `lstat` and offers refresh rather than opening/editing the wrong file.
- Verify Walker Little and privileged Wombat Walker never share databases.

**Human confirmation test**

- Deep-scan a harmless project tree, search for a remembered filename fragment, select the result,
  and confirm Walker opens the correct live parent folder. Change the file, repeat, and confirm
  the displayed cache age/status makes the difference clear.

### Step 3b — Add separate Docker inventory, cache, and search

Keep the Docker workspace as a separate Walker area reached through Utilities. First store only
read-only discovery data: containers, their images/status/sizes, and their declared mounts. Then
add optional scans and metadata search using the Docker-specific tables above; do not scan Docker
storage automatically when Walker starts.

Docker paths must be displayed with their container and mount context. A bind mount should offer a
safe jump to its ordinary host path; a named volume must display both the Docker volume name and
its container destination. The live container filesystem is disposable by default, whereas bind
mounts and named volumes are persistent—but persistence does not make a mount safe to delete.

**Agent success conditions**

- Docker tables are created/migrated independently of `scan_roots`, `path_entries`, and their FTS
  index; normal filesystem search never returns Docker records and Docker search never returns host
  records unless the user deliberately changes workspaces.
- A fixture with one bind mount and one named volume records their type, source/name, destination,
  and read/write state correctly. Recreating the container produces a new container identity and
  visibly stale prior container scan rather than silently reusing it.
- A Docker scan of a running fixture container records only metadata and cannot execute arbitrary
  shell text supplied by the user. A stopped container clearly reports that its live filesystem is
  unavailable while still showing known persistent mounts.
- Docker search results include container name, container ID, mount/volume context, scan timestamp,
  and completion status. No Docker action writes, copies, deletes, starts, stops, or restarts a
  container in this step.

**Human confirmation test**

- Open Docker workspace, inspect a container with a named volume, and confirm that Walker explains
  the difference between its ephemeral container files and persistent mounted data. Scan a harmless
  mounted test folder, search for a known file, recreate the container, then confirm Walker labels
  the old container inventory as stale instead of presenting it as current.

### Step 3c — Add guarded Docker data management

Only after Step 3b is complete, allow a user to mark a specific read/write bind mount or named
volume as **managed data**. Copy-out comes first. Permanent purge is limited to a selected path
inside such a marked mount, always shows container, volume/bind source, full path, item count and
size, requires an exact `PURGE` confirmation (and `PURGE FOLDER` for a directory), and writes a
`docker_cleanup_audit` row. Never offer Docker cleanup for the container writable layer, read-only
mounts, tmpfs, unreviewed mounts, or special files.

Do not implement overwrite-with-zeroes as a security promise: it is unreliable on SSDs,
copy-on-write storage, RAID, snapshots, and Docker layers. A permanent purge honestly removes the
selected directory entries and reclaims blocks when no process has them open.

**Agent success conditions**

- An unreviewed writable mount is browse/copy-only; no purge action is shown until the user marks
  that exact mount as managed data.
- A purge test fixture requires the exact confirmation, removes only the selected fixture path,
  records the audit result, and leaves adjacent volume data intact. Cancellation, wrong text,
  read-only mount, and container writable-layer tests make no change.
- Copy-out to a selected host folder reports success only after destination existence and expected
  size are verified. It never deletes the source as a side effect of copy-out.

**Human confirmation test**

- Mark a disposable named-volume test folder as managed data, copy one file to a host folder,
  verify it opens correctly, then purge a second disposable test file after reading the displayed
  mount/path/size warning. Confirm the audit view records the purge and that a database/config
  volume remains unreviewed and has no purge option.

### Step 3d — Add Docker cleanup audit and stale-resource review

Add a separate Docker cleanup report. It is an inspection and explicit-action workspace, never a
wrapper around a broad `docker system prune` command. It must distinguish between:

| Category | Meaning | Default action |
|---|---|---|
| Stale Walker inventory | A previously scanned container ID no longer exists, commonly after recreation. It consumes Walker metadata only, not Docker disk space. | Label stale; allow removal of the cache record separately. |
| Stopped/exited/dead container | A real Docker container remains but is not running. | Show image, age, writable-layer size, and mounts; inspect before any removal. |
| Dangling image | Untagged image layer not referenced by a container. | Show exact image ID and reclaimable size; require explicit selected removal. |
| Unused named volume | Persistent volume unattached to any current container. It may hold the only copy of an old application's data. | High-risk review only by default; show labels, age, size, and contents/mount history before an explicit removal. |
| Build cache | Docker build artefacts that may be reclaimable. | Show total and individual entries where Docker supplies them; require explicit confirmation. |
| Possible Compose leftover | Resource labels suggest a Compose project no longer has active matching containers. This is a review candidate, not proof it is junk. | Explain the evidence and require manual review. |

Use `docker_resource_inventory` to retain inventory history and identify resources that disappeared
between checks. A container scan whose container ID is absent from the latest live inventory becomes
**stale**; do not merge it into a newly recreated container merely because the human-readable name
matches. Search results must show this state and hide stale records by default unless the user asks
to include them.

The report must show exact resources and sizes before any cleanup. Removal is always per selected
container, image, volume, cache entry, or stale cache record, with a strong resource-specific
confirmation and `docker_cleanup_audit` result. Do not offer automatic deletion of volumes or a
one-button “clean everything” action. A user may deliberately run Docker's own pruning commands
outside Walker, but Walker must not hide their scope behind a generic confirmation.

**Agent success conditions**

- Fixture inventory includes a running container, an exited container, an untagged dangling image,
  a detached named volume, and a recreated container with the same name but a new ID. Each appears
  in the correct category; the previous container scan is marked stale.
- The report never counts stale Walker metadata as reclaimable Docker disk space. It shows Docker
  images, containers, volumes, and build cache as distinct categories, not one misleading total.
- Inspecting every category is read-only. Cancellation, malformed selection, and an unreviewed
  volume make no Docker change.
- Selected disposable-fixture image/container/cache removal requires the exact confirmation,
  removes only that resource, refreshes inventory, and appends an audit row. Volume removal tests
  require an additional high-risk confirmation and prove adjacent volumes remain untouched.

**Human confirmation test**

- Create a disposable stopped test container and a disposable named volume, open the report, and
  confirm their type, size, labels, and warning wording are understandable. Recreate a scanned test
  container under the same name and confirm the old result becomes stale. Remove only the stopped
  test container after inspection; verify that the volume is still present and that no broad prune
  command was run.

### Step 3e — Add shared destination picker and host file management

Build one reusable **select destination folder** mode in the shared Walker engine. It must be used
by ordinary Walker copy/move, future Docker copy-out, Wombat Backups local-destination selection,
and the later GUI backend. Users browse to a destination folder and choose `[.] Use this folder`;
they must not be required to find and paste a long path manually, although manual entry remains an
optional advanced shortcut.

Expand the ordinary host file-action menu for accessible regular files, and the current-folder
Utilities action for folders, to offer:

```text
[1] Move to Trash (recoverable)
[2] Copy to another folder
[3] Move to another folder
[4] Permanently purge
[q] Return without changes
```

Copy and move must never overwrite an existing destination silently. On a name collision, present
explicit choices to cancel, skip, choose a new name, or replace only after a separate warning.
For an across-filesystem move, copy into a private temporary destination, verify the completed
destination's existence and expected size, rename it into its final name, then remove the source.
For a same-filesystem move, prefer an atomic rename. Never delete the source before a successful
destination verification.

Trash remains the normal cleanup path for accessible host data. Permanent purge is a separate
action: show canonical path, file/folder type, total logical size, and folder item count; require
exact `PURGE` for a file and `PURGE FOLDER` for a folder. Do not offer copy, move, Trash, or purge
through sudo in this step. Protected system paths remain view/edit-only; symlinks, devices, and
other special files receive a clear explanation and no destructive action. Do not promise secure
overwrite with zeroes for SSD, copy-on-write, RAID, snapshots, or Docker storage.

After a successful host operation, invalidate or targeted-refresh the cached source and destination
subtrees and append a `file_operations_audit` row. The later Docker copy-out flow must reuse this
destination picker and the same copy-then-verify rule, while Docker permanent purge remains limited
to explicitly marked managed-data mounts under Step 3c.

**Agent success conditions**

- Destination-picker fixtures prove that current-folder selection, navigation, cancellation, paths
  with spaces, and an inaccessible destination all behave correctly; no caller has to parse menu
  text to obtain the selected folder.
- Copying a fixture file/folder preserves its contents and records an audit row. Existing
  destination names are never overwritten without the explicit replacement confirmation.
- Same-filesystem move uses rename where possible. Cross-filesystem move copies, verifies size,
  installs the completed destination, then removes the source; simulated copy/verification failure
  leaves the source intact and does not expose a partial final destination.
- Wrong purge confirmation, cancellation, a root path, a protected path, a symlink, and a special
  file all make no change. Successful purge and Trash actions record their outcome and correctly
  mark cached totals stale.

**Human confirmation test**

- In a disposable user-owned test tree, copy a folder with spaces to a second mounted filesystem,
  compare its contents, then move it back and confirm the source remains until the destination is
  verified. Trash one test file, permanently purge another only after reading the full warning, and
  inspect the operation audit. Confirm that `/etc` and a symbolic link offer no destructive menu.

### Step 4 — Add Wombat Walker editing controls

Complete the privileged Wombat Walker entry point. It must be explicitly launched with sudo,
and expose only view/Nano/Vim after selection and confirmation.

**Agent success conditions**

- Walker Little cannot browse a root-only fixture; Wombat Walker can.
- Wombat Walker displays hidden entries according to its flag/default.
- Declining `EDIT` makes no change; accepting it opens only the selected regular file through the
  approved editor route.
- Attempting to select a directory for edit, a symlink escape, or a non-regular file fails safely.
- The installed production wrapper is root-owned and no ordinary user can modify it.

**Human confirmation test**

- As an administrator, browse `/etc`, view a harmless configuration file, cancel one edit, then
  edit a disposable test file with Nano or Vim and verify only that file changes.

### Step 5 — Add user and system installation modes

Implement `install-wombat-walker.sh --user|--system` exactly as described in the installation
model. The system installer must be explicit about every system path and every sudoers change;
the user installer must not ask for sudo or touch system paths.

**Agent success conditions**

- In a temporary HOME, `--user` installs a runnable ordinary command, private directories, and no
  root-owned files, sudoers files, or `/var/lib` data.
- `--system` refuses to run without root, installs every privileged component as `root:root`, and
  leaves no user-writable parent directory in the privileged execution path.
- Test that a non-sudo user can run the user installation but cannot invoke the privileged worker.
- Test that an authorised sudo user can request only documented fixed worker actions, not arbitrary
  commands or arguments.
- Uninstall tests show exact targets and require confirmation; user and system installations are
  never removed by the other mode.

**Human confirmation test**

- Install `--user` as a non-sudo test account and confirm `wombat-walker --here` works only within
  that account's access. Then have an administrator perform `--system`, inspect root ownership and
  permissions, and confirm an authorised user receives a sudo prompt only for a protected action.

### Step 6 — Documentation, help, and integration tests

Add every public flag to `help.md` in the same change. Document the distinction between current,
cached, and incomplete size information; Wombat Walker versus Walker Little privilege;
`sudoedit`; and Walker Little's read-only guarantee.

**Completion definition**

The feature is complete when privileged Wombat Walker is genuinely useful as an everyday server
maintenance explorer, Wombat Backups reuses Walker Little's safe path selector, and cached scan
results never masquerade as live data.
