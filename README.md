# 🐾 Wombat Walker

<p align="center">
  <img src="pics/wombat-walker15.png" alt="Wombat Walker exploring a Linux filesystem" width="900">
</p>

> A practical terminal file explorer for Linux servers — built for people who live in terminals,
> manage real disks, and occasionally need to find where the missing gigabytes went.

Wombat Walker turns ordinary shell navigation into a clear, interactive file-management workspace.
Browse folders, see human-readable sizes and modification dates, sort what matters, search a saved
filesystem inventory, edit files safely, clean up data deliberately, and return to the same place
when you are done. It is designed to be useful on its own every day, not merely as a helper for
another application.

## ✨ Why Wombat Walker?

- 📁 **Readable filesystem browsing** — files, folders, sizes, allocated disk space, dates, paging,
  hidden-file control, search, and remembered display preferences.
- 🔎 **Truthful folder search** — search filenames and paths in the current folder after Walker refreshes
  its metadata, or search the wider saved filesystem and Docker inventories.
- 🧹 **Careful cleanup** — preview files and recoverable Wombat Trash actions before deleting host
  data; move, copy, rename, and create folders with destination and overwrite guards.
- ✏️ **Safe editing** — inspect a regular file, choose Nano/Vim/system editor, and return directly
  to Walker. Protected editing is explicit and never silently elevates privileges.
- 🖥️ **A shell exactly where you are** — open a normal nested shell in the current Walker folder,
  run any expert command, type `exit`, and return to Walker.

## 🐳 Docker is a first-class feature

Docker storage is often where server disk space becomes mysterious: writable container layers,
image layers, named volumes, bind mounts, temporary job folders, and data hidden behind long paths.
Walker has a dedicated Docker workspace so you do not have to piece this together from scattered
`docker inspect`, `docker exec`, and `du` commands.

Open it with `wombat-walker --docker`, or use Walker Utilities → **Browse Docker containers and
storage**. It lists containers with status, image/layer size, virtual size, and optional measured
persistent data. Select a running container to browse its live filesystem, inspect exactly where
named volumes and bind mounts connect, save searchable metadata scans, and find large files.

For data stored in a verified read/write named volume or bind mount, Walker supports guarded cleanup.
It never presents Docker deletion as recoverable: previews show the matching paths and space, then
require explicit typed confirmations. This is particularly useful for job queues such as
`jobs/<job-id>/chapter_*.wav`, where a completed archive exists but many gigabytes of intermediate
audio remain.

## 🚀 Install

Clone the project, then run the installer:

```bash
git clone https://github.com/RochmanReese/wombat-walker.git
cd wombat-walker
scripts/install-wombat-walker.sh
```

The normal install uses sudo once and creates a root-owned system installation plus the
`wombat-walker` command in `/usr/local/bin`. Root-owned program files are important because Walker's
optional protected-folder tools use carefully limited sudo actions.

No sudo on the server? Use a normal user install instead:

```bash
scripts/install-wombat-walker.sh --user
```

Normal browsing, search, cleanup, file management, and Docker work in user mode. Protected host
browsing and editing are intentionally unavailable because a user-writable installation must never
be trusted as a sudo helper.

### 📦 Dependencies

Walker is deliberately lightweight. It needs Bash, Python 3 with SQLite FTS5, and normal GNU/Linux
tools such as `find`, `stat`, `du`, `df`, `sort`, `awk`, `sed`, `realpath`, `mktemp`, and `mountpoint`.
The installer detects common package managers and verifies the requirements.

`less` enables safe viewing; Nano, Vim, or a system editor enables editing. Docker is optional but
strongly recommended for Docker hosts; request package installation with `--with-docker`.

## 🧭 Everyday use

```bash
# Open your home directory.
wombat-walker --home

# Open the folder you are currently working in.
wombat-walker --here

# Start at any specific path.
wombat-walker /media/wombat/2TBStorage

# Go straight to Docker storage exploration.
wombat-walker --docker
```

Inside Walker, the bottom of each view shows the available keys. The most commonly used are:

| Key | What it does |
|---|---|
| `.` | In picker mode, returns the current folder to the calling app. |
| `u` / `d` | Go up one folder / return to the previous folder. |
| `o` | Change folder display order. |
| `s` | Choose a scope, refresh if needed, and search; refine results by size. |
| `x` | Open Help & utilities: Docker, mounts, scan refresh, cleanup, preferences, help, and shell. |
| `!` | Open a normal shell in the current folder; type `exit` to return. |
| `q` | Return or quit safely. |

## 🔎 Scans and search

A live folder listing is immediate. A **saved scan** is optional metadata—paths, types, sizes, and
timestamps—not file contents. It makes later searches fast and is especially valuable on archive
drives or large Docker installations.

When you choose **Search folders & files**, Walker first asks which scope to search. A selected
folder can be refreshed before searching so its results include current files. You can search the
current folder, all its descendants, another chosen folder, every saved host scan, or a combined
host-and-Docker view. From the results screen, use **[f] Refine search** to narrow
a large result set by minimum or maximum logical file size (for example, `100MB`). Utilities →
**Update saved scan below this folder** remains available when you want to refresh an inventory
without searching. Search results can be sorted
alphabetically, by logical size, or by last modified date. A search for an Ollama model name may
not find its large weight blobs because Ollama stores them as SHA-256 filenames; browse the blobs
folder and sort by size instead.

## 🛡️ Safety model

Walker is deliberately opinionated about risky actions:

- Host cleanup goes to portable **Wombat Trash** first, so it can be restored or permanently emptied
  later inside Walker.
- Copy, move, rename, and create-folder actions show the target and require a typed confirmation.
  Walker never overwrites an existing path or follows symlinks.
- Convenience file management is blocked for protected system paths such as `/etc`, `/usr`, `/boot`,
  `/proc`, `/sys`, `/dev`, `/run`, and Docker's `/var/lib/docker` storage.
- Docker cleanup is permanent because moving multi-gigabyte temporary data to Trash does not free
  space. It is restricted to verified read/write volumes or bind mounts and uses two confirmations.
- Sudo is requested only for an explicit protected action, never for normal browsing or deletion.

## ⌨️ Command-line reference

| Command / flag | Purpose |
|---|---|
| `wombat-walker [path]` | Starts Walker in the optional path; otherwise it starts at `/`. |
| `--home` | Starts in the logged-in user's home folder. |
| `--here` | Starts in the directory from which the command was launched. |
| `--docker` | Opens Docker workspace directly: containers, mounts, live browsing, scans, search, and guarded data cleanup. |
| `--filesize on\|off` | Shows file/folder size information; turn it off for faster browsing on slow storage. |
| `--items-per-page 1-200` | Sets displayed rows for this run. The in-app setting is remembered for later sessions. |
| `--sort alphabetical\|largest\|smallest\|updated` | Sets initial folder order. Largest/smallest requires `--filesize on`. |
| `--hidden on\|off` | Includes or hides dotfiles. Hidden files are added to the normal listing; they do not replace it. |
| `--deep-scan current\|filesystem` | Saves an accessible metadata inventory for the current folder or its filesystem. Use `--sudo` only when an explicit protected inventory is required. |
| `--show-scan current\|filesystem` | Displays entries from a previously saved scan without re-walking the drive. |
| `--show-limit 1-10000` | Limits rows shown by `--show-scan`. |
| `--list-scans` | Lists saved normal-user scan roots and their status. |
| `--search <words>` | Searches saved host metadata. Multiple words must match; use a slash when intentionally searching a path. |
| `--root <scan-root>` | Limits `--search` to one saved scan root. |
| `--search-limit 1-10000` | Limits displayed `--search` results. Interactive results support pages and ordering. |
| `--set-policy active\|archive\|manual --root <scan-root>` | Records how a saved root should be treated on later refreshes. Archive/manual roots are not candidates for automatic refresh behaviour. |
| `--sudo` | Enables only the narrow protected scan/show/search/policy worker; valid only with those cache actions. |
| `--pick-folder` | Integration mode for another Wombat app: `.` returns the selected folder path. |
| `--help` | Prints the built-in command guide. |

`--privileged-browse` and `--file-action` are internal integration actions. They are intentionally
not part of the normal user workflow.

## 🧰 Docker host setup

Walker needs the Docker CLI and access to the Docker daemon. On many distributions that means adding
the intended user to the `docker` group, then logging out and back in. This is a significant privilege
decision: Docker access is effectively powerful host access, so make it deliberately.

Once `docker info` works as your normal user, Walker's Docker workspace will work too.

## 📚 Development notes

- `scripts/` contains the Bash runtime, SQLite metadata helper, portable Trash helper, protected
  worker, and installer.
- `briefs/` contains the product and cleanup implementation briefs.
- Run `wombat-walker --help` for the terminal guide and `[?]` from Utilities for in-app help.

---

Built for people who prefer understanding their server to guessing at it. 🐾
