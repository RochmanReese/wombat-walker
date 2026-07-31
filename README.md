# Wombat Walker

Wombat Walker is a terminal-first Linux filesystem explorer and cleanup tool. It provides readable
folder browsing, cached metadata scans and search, safe file editing, portable Trash management,
guarded copy/move/rename operations, and optional Docker container and volume exploration.

## Install

From this repository:

```bash
scripts/install-wombat-walker.sh
```

This creates the `wombat-walker` command, usable from any folder. The normal install is system-wide
and uses sudo once so protected-folder features can be used safely. Use `--user` only when the
machine does not provide sudo/root access; normal Walker and Docker features remain available, while
protected host browsing and editing are disabled.

```bash
wombat-walker --home
wombat-walker --here
wombat-walker --docker
```

The runtime has no Restic, Rclone, Pillow, or backup-project dependency. Docker is optional but
fully supported when installed and accessible to the current user.

## Layout

- `scripts/` — Walker runtime, SQLite metadata helper, Trash helper, protected worker, installer.
- `briefs/` — product and cleanup implementation briefs.

Run `wombat-walker --help` for command-line options and use `[?]` inside Walker for the offline
guide.
