#!/usr/bin/env python3
"""Private SQLite storage for Wombat Walker scan metadata.

Usage:
  wombat-walker-db.py init <absolute-db-path>
  wombat-walker-db.py status <absolute-db-path>
  wombat-walker-db.py scan <absolute-db-path> <directory> <admin|little>
  wombat-walker-db.py show <absolute-db-path> <directory> [limit]
  wombat-walker-db.py list <absolute-db-path>
  wombat-walker-db.py set-policy <absolute-db-path> <root> <active|archive|manual>
  wombat-walker-db.py cached-sizes <absolute-db-path> <directory> <admin|little>
  wombat-walker-db.py mark-stale <absolute-db-path> <changed-directory>
  wombat-walker-db.py operation-log <absolute-db-path> <trash_move|restore|trash_purge> <path> <file|directory> <logical-bytes> <allocated-bytes> <success|failed|skipped> <detail>
  wombat-walker-db.py operation-list <absolute-db-path> [limit]
  wombat-walker-db.py set-encryption <absolute-db-path> <directory> <self|descendants>
  wombat-walker-db.py remove-encryption <absolute-db-path> <directory>
  wombat-walker-db.py list-encryption <absolute-db-path>
  wombat-walker-db.py list-mounts <absolute-db-path>
  wombat-walker-db.py docker-inventory <absolute-db-path>
  wombat-walker-db.py docker-scan <absolute-db-path> <container-id> <absolute-container-path>
  wombat-walker-db.py docker-session-summary <absolute-db-path> <started-at>
  wombat-walker-db.py docker-folder-total <absolute-db-path> <container-id> <absolute-container-path>
  wombat-walker-db.py docker-search <absolute-db-path> <words> [limit]
  wombat-walker-db.py docker-search-path <absolute-db-path> <words> <number>
  wombat-walker-db.py search <absolute-db-path> <words> <root-or-dash> [limit]
  wombat-walker-db.py search-path <absolute-db-path> <words> <root-or-dash> <number>

The database contains metadata only: paths, filesystem identifiers, sizes, timestamps, scan
history, and scan errors. It never stores file contents, credentials, or editor buffers.
"""
import json
import os
import re
import queue
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = """
CREATE TABLE IF NOT EXISTS scan_roots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root_path TEXT NOT NULL UNIQUE,
    device_id INTEGER,
    privilege_context TEXT NOT NULL CHECK (privilege_context IN ('admin', 'little')),
    filesystem_uuid TEXT,
    filesystem_label TEXT,
    last_mount_path TEXT,
    root_relative_path TEXT,
    refresh_policy TEXT NOT NULL DEFAULT 'manual' CHECK (refresh_policy IN ('active', 'archive', 'manual')),
    last_full_scan_at TEXT,
    last_partial_scan_at TEXT,
    totals_stale INTEGER NOT NULL DEFAULT 0 CHECK (totals_stale IN (0, 1)),
    last_status TEXT CHECK (last_status IN ('complete', 'incomplete', 'failed'))
);
CREATE TABLE IF NOT EXISTS scan_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
    scope TEXT NOT NULL DEFAULT 'full' CHECK (scope IN ('full', 'targeted')),
    scanned_path TEXT,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL CHECK (status IN ('running', 'complete', 'incomplete', 'failed')),
    entry_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    logical_bytes INTEGER NOT NULL DEFAULT 0,
    allocated_bytes INTEGER NOT NULL DEFAULT 0,
    scanner_version TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS path_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    basename TEXT NOT NULL,
    device_id INTEGER,
    inode INTEGER,
    entry_type TEXT NOT NULL CHECK (entry_type IN ('file', 'directory', 'symlink', 'other')),
    logical_size_bytes INTEGER,
    allocated_size_bytes INTEGER,
    mtime_ns INTEGER,
    ctime_ns INTEGER,
    last_seen_scan_id INTEGER NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    UNIQUE(root_id, path)
);
CREATE TABLE IF NOT EXISTS directory_totals (
    root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    logical_total_bytes INTEGER,
    allocated_total_bytes INTEGER,
    newest_mtime_ns INTEGER,
    calculated_scan_id INTEGER NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    PRIMARY KEY(root_id, path)
);
CREATE TABLE IF NOT EXISTS scan_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id INTEGER NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    operation TEXT NOT NULL,
    error_text TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS path_encryption_labels (
    path TEXT PRIMARY KEY,
    applies_to_descendants INTEGER NOT NULL CHECK (applies_to_descendants IN (0, 1)),
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS file_operation_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at TEXT NOT NULL,
    actor_user TEXT NOT NULL,
    actor_uid INTEGER NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('trash_move', 'restore', 'trash_purge')),
    original_path TEXT NOT NULL,
    entry_type TEXT NOT NULL CHECK (entry_type IN ('file', 'directory')),
    logical_size_bytes INTEGER,
    allocated_size_bytes INTEGER,
    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failed', 'skipped')),
    detail TEXT
);
CREATE INDEX IF NOT EXISTS idx_file_operation_audit_occurred ON file_operation_audit(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_path_entries_root_path ON path_entries(root_id, path);
CREATE INDEX IF NOT EXISTS idx_path_entries_root_mtime ON path_entries(root_id, mtime_ns DESC);
CREATE VIRTUAL TABLE IF NOT EXISTS path_search USING fts5(
    path, basename, root_id UNINDEXED, entry_id UNINDEXED,
    tokenize='unicode61 remove_diacritics 2'
);
CREATE TABLE IF NOT EXISTS docker_containers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    image TEXT,
    status TEXT,
    writable_size_bytes INTEGER,
    virtual_size_bytes INTEGER,
    created_at TEXT,
    labels_json TEXT NOT NULL DEFAULT '{}',
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    last_inventory_at TEXT NOT NULL,
    is_stale INTEGER NOT NULL DEFAULT 0 CHECK (is_stale IN (0, 1))
);
CREATE TABLE IF NOT EXISTS docker_mounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_row_id INTEGER NOT NULL REFERENCES docker_containers(id) ON DELETE CASCADE,
    mount_type TEXT NOT NULL,
    volume_name TEXT,
    host_source TEXT,
    container_destination TEXT NOT NULL,
    read_write INTEGER NOT NULL CHECK (read_write IN (0, 1)),
    safety_state TEXT NOT NULL DEFAULT 'unreviewed' CHECK (safety_state IN ('unreviewed', 'managed_data', 'blocked')),
    last_seen_at TEXT NOT NULL,
    UNIQUE(container_row_id, container_destination)
);
CREATE TABLE IF NOT EXISTS docker_scan_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_row_id INTEGER REFERENCES docker_containers(id) ON DELETE SET NULL,
    mount_id INTEGER REFERENCES docker_mounts(id) ON DELETE SET NULL,
    scope TEXT NOT NULL CHECK (scope IN ('inventory', 'container', 'mount')),
    scanned_path TEXT NOT NULL DEFAULT '/',
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL CHECK (status IN ('running', 'complete', 'incomplete', 'failed')),
    entry_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS docker_path_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_id INTEGER NOT NULL REFERENCES docker_scan_runs(id) ON DELETE CASCADE,
    container_row_id INTEGER NOT NULL REFERENCES docker_containers(id) ON DELETE CASCADE,
    mount_id INTEGER REFERENCES docker_mounts(id) ON DELETE SET NULL,
    container_path TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    basename TEXT NOT NULL,
    entry_type TEXT NOT NULL CHECK (entry_type IN ('file', 'directory', 'symlink', 'other')),
    logical_size_bytes INTEGER,
    allocated_size_bytes INTEGER,
    mtime_ns INTEGER,
    UNIQUE(scan_id, container_path)
);
CREATE INDEX IF NOT EXISTS idx_docker_containers_seen ON docker_containers(last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_docker_mounts_container ON docker_mounts(container_row_id, container_destination);
CREATE INDEX IF NOT EXISTS idx_docker_path_entries_container_path ON docker_path_entries(container_row_id, container_path);
CREATE VIRTUAL TABLE IF NOT EXISTS docker_path_search USING fts5(
    container_path, basename, container_name, volume_name, entry_id UNINDEXED,
    tokenize='unicode61 remove_diacritics 2'
);
"""


class DatabaseError(Exception):
    pass


def fail(message):
    raise DatabaseError(message)


def database_path(raw_path):
    path = Path(raw_path)
    if not path.is_absolute():
        fail("database path must be absolute")
    return path


def check_parent(path, create=False):
    parent = path.parent
    if create:
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(parent, 0o700)
    try:
        info = os.lstat(parent)
    except FileNotFoundError:
        fail(f"database parent does not exist: {parent}")
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail(f"database parent is not a real directory: {parent}")
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        fail(f"database parent must be owned by this user and mode 0700: {parent}")


def check_database(path, must_exist=True):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if must_exist:
            fail(f"database does not exist: {path}")
        return
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail(f"database must be a regular non-symlink file: {path}")
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        fail(f"database must be owned by this user and mode 0600: {path}")


def connect(path):
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def cmd_init(path):
    old_umask = os.umask(0o077)
    try:
        check_parent(path, create=True)
        check_database(path, must_exist=False)
        conn = connect(path)
        conn.executescript(SCHEMA)
        root_columns = {row[1] for row in conn.execute("PRAGMA table_info(scan_roots)")}
        run_columns = {row[1] for row in conn.execute("PRAGMA table_info(scan_runs)")}
        root_migrations = {
            "filesystem_uuid": "ALTER TABLE scan_roots ADD COLUMN filesystem_uuid TEXT",
            "filesystem_label": "ALTER TABLE scan_roots ADD COLUMN filesystem_label TEXT",
            "last_mount_path": "ALTER TABLE scan_roots ADD COLUMN last_mount_path TEXT",
            "root_relative_path": "ALTER TABLE scan_roots ADD COLUMN root_relative_path TEXT",
            "refresh_policy": "ALTER TABLE scan_roots ADD COLUMN refresh_policy TEXT NOT NULL DEFAULT 'manual'",
            "last_partial_scan_at": "ALTER TABLE scan_roots ADD COLUMN last_partial_scan_at TEXT",
            "totals_stale": "ALTER TABLE scan_roots ADD COLUMN totals_stale INTEGER NOT NULL DEFAULT 0",
        }
        run_migrations = {
            "logical_bytes": "ALTER TABLE scan_runs ADD COLUMN logical_bytes INTEGER NOT NULL DEFAULT 0",
            "allocated_bytes": "ALTER TABLE scan_runs ADD COLUMN allocated_bytes INTEGER NOT NULL DEFAULT 0",
            "scope": "ALTER TABLE scan_runs ADD COLUMN scope TEXT NOT NULL DEFAULT 'full'",
            "scanned_path": "ALTER TABLE scan_runs ADD COLUMN scanned_path TEXT",
        }
        docker_run_columns = {row[1] for row in conn.execute("PRAGMA table_info(docker_scan_runs)")}
        for column, statement in root_migrations.items():
            if column not in root_columns:
                conn.execute(statement)
        for column, statement in run_migrations.items():
            if column not in run_columns:
                conn.execute(statement)
        if "scanned_path" not in docker_run_columns:
            conn.execute("ALTER TABLE docker_scan_runs ADD COLUMN scanned_path TEXT NOT NULL DEFAULT '/'")
        conn.commit()
        conn.close()
        os.chmod(path, 0o600)
        check_database(path)
    finally:
        os.umask(old_umask)


def cmd_status(path):
    check_parent(path)
    check_database(path)
    conn = connect(path)
    tables = {name for (name,) in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")}
    required = {"scan_roots", "scan_runs", "path_entries", "directory_totals", "scan_errors", "path_search", "docker_containers", "docker_mounts", "docker_scan_runs", "docker_path_entries", "docker_path_search"}
    missing = sorted(required - tables)
    if missing:
        fail("database schema is incomplete: " + ", ".join(missing))
    counts = {}
    for table in ("scan_roots", "scan_runs", "path_entries", "directory_totals", "scan_errors", "docker_containers", "docker_mounts", "docker_scan_runs", "docker_path_entries"):
        counts[table] = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    conn.close()
    print("ready " + " ".join(f"{key}={value}" for key, value in counts.items()))


def cmd_show(path, root, limit):
    check_parent(path)
    check_database(path)
    root = os.path.realpath(root)
    conn = connect(path)
    row = conn.execute("SELECT id, last_full_scan_at, last_partial_scan_at, last_status, refresh_policy, totals_stale, filesystem_uuid, filesystem_label, last_mount_path FROM scan_roots WHERE root_path=?", (root,)).fetchone()
    if not row:
        fail(f"no saved scan exists for: {root}")
    root_id, scanned_at, partial_at, status, policy, totals_stale, filesystem_uuid, filesystem_label, last_mount_path = row
    run = conn.execute("SELECT entry_count, error_count, logical_bytes, allocated_bytes FROM scan_runs WHERE root_id=? AND status != 'running' ORDER BY id DESC LIMIT 1", (root_id,)).fetchone()
    total = conn.execute("SELECT logical_total_bytes, allocated_total_bytes FROM directory_totals WHERE root_id=? AND path=?", (root_id, root)).fetchone()
    print(f"Saved scan: {root}")
    print(f"Policy: {policy}    Full scan status: {status or 'unknown'}    Completed: {scanned_at or 'unknown'}")
    if filesystem_uuid:
        drive_name = filesystem_label or "unlabelled filesystem"
        print(f"Drive identity: {drive_name}    UUID: {filesystem_uuid}    Last mount: {last_mount_path or 'unknown'}")
    if partial_at:
        print(f"Last targeted refresh: {partial_at}")
    if totals_stale:
        print("Whole-root total: stale after targeted refresh; run a full scan when an exact disk total is needed.")
    if run:
        print(f"Entries: {run[0]:,}    Unreadable paths: {run[1]:,}")
        print(f"Logical file size: {human_bytes(run[2])}    Allocated disk space: {human_bytes(run[3])}")
    if total:
        print(f"Saved root total: {human_bytes(total[0])} logical    {human_bytes(total[1])} allocated")
    print()
    print(f"{'Type':<10} {'Size':>12}  {'Last modified':<16}  Path")
    rows = conn.execute("SELECT entry_type, logical_size_bytes, mtime_ns, path FROM path_entries WHERE root_id=? ORDER BY path LIMIT ?", (root_id, limit)).fetchall()
    for entry_type, size, mtime_ns, entry_path in rows:
        print(f"{entry_type:<10} {human_bytes(size or 0):>12}  {format_time(mtime_ns):<16}  {entry_path}")
    all_count = conn.execute("SELECT COUNT(*) FROM path_entries WHERE root_id=?", (root_id,)).fetchone()[0]
    if all_count > len(rows):
        print(f"\nShowing {len(rows)} of {all_count} entries. Use --show-limit to display more.")
    conn.close()


def cmd_list(path):
    check_parent(path)
    check_database(path)
    conn = connect(path)
    rows = conn.execute("SELECT root_path, refresh_policy, last_status, last_full_scan_at, last_partial_scan_at, totals_stale, filesystem_uuid, filesystem_label, last_mount_path FROM scan_roots ORDER BY last_full_scan_at DESC, root_path").fetchall()
    if not rows:
        print("No saved scans yet.")
    else:
        print("Policy    Status       Full scan                   Targeted refresh            Scan root")
        for root_path, policy, status, scanned_at, partial_at, totals_stale, filesystem_uuid, filesystem_label, last_mount_path in rows:
            stale = " (total stale)" if totals_stale else ""
            print(f"{policy:<9} {(status or 'unknown'):<12} {(scanned_at or 'unknown'):<27} {(partial_at or '-'): <27} {root_path}{stale}")
            if filesystem_uuid:
                print(f"  Drive: {filesystem_label or 'unlabelled'}    UUID: {filesystem_uuid}    Last mount: {last_mount_path or 'unknown'}")
    conn.close()


def cmd_set_policy(path, root, policy):
    if policy not in {"active", "archive", "manual"}:
        fail("refresh policy must be active, archive, or manual")
    check_parent(path)
    check_database(path)
    root = os.path.realpath(root)
    conn = connect(path)
    changed = conn.execute("UPDATE scan_roots SET refresh_policy=? WHERE root_path=?", (policy, root)).rowcount
    conn.commit()
    conn.close()
    if not changed:
        fail(f"no saved scan exists for root: {root}")
    print(f"Saved scan policy: {root} → {policy}")


def cmd_cached_sizes(path, directory, context):
    if context not in {"admin", "little"}:
        fail("cache context must be admin or little")
    check_parent(path)
    check_database(path)
    directory = os.path.realpath(directory)
    conn = connect(path)
    candidates = conn.execute("SELECT id, root_path, last_status, totals_stale FROM scan_roots WHERE privilege_context=?", (context,)).fetchall()
    candidates = [candidate for candidate in candidates if is_within(directory, candidate[1])]
    if not candidates:
        fail(f"no saved scan contains: {directory}")
    root_id, root_path, status, totals_stale = max(candidates, key=lambda candidate: len(candidate[1]))
    prefix = directory if directory == "/" else directory + "/"
    rows = conn.execute("SELECT path, entry_type, logical_size_bytes, allocated_size_bytes FROM path_entries WHERE root_id=? AND (path=? OR substr(path, 1, length(?))=?)", (root_id, directory, prefix, prefix)).fetchall()
    totals = {}
    folder_total = 0
    folder_allocated_total = 0
    for entry_path, entry_type, logical_size, allocated_size in rows:
        if entry_path == directory:
            continue
        relative = entry_path[len(prefix):]
        if not relative:
            continue
        child_path = prefix + relative.split("/", 1)[0]
        if entry_type == "file":
            logical = logical_size or 0
            allocated = allocated_size or 0
            child_totals = totals.setdefault(child_path, [0, 0])
            child_totals[0] += logical
            child_totals[1] += allocated
            folder_total += logical
            folder_allocated_total += allocated
        else:
            totals.setdefault(child_path, [0, 0])
    output = sys.stdout.buffer
    for value in ("META", root_path, status or "unknown", str(totals_stale), str(folder_total), str(folder_allocated_total)):
        output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    for child_path, (logical, allocated) in totals.items():
        for value in ("SIZE", child_path, str(logical), str(allocated)):
            output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    conn.close()


def cmd_mark_stale(path, changed_directory):
    """Mark saved roots containing a live changed directory as stale."""
    check_parent(path)
    check_database(path)
    changed_directory = os.path.realpath(changed_directory)
    conn = connect(path)
    updated = conn.execute(
        """UPDATE scan_roots
           SET totals_stale=1
           WHERE root_path = ?
              OR (root_path = '/' AND ? LIKE '/%')
              OR (? LIKE root_path || '/%')""",
        (changed_directory, changed_directory, changed_directory),
    ).rowcount
    conn.commit()
    conn.close()
    print(f"Marked {updated} saved scan root(s) stale.")


def cmd_operation_log(path, action, original_path, entry_type, logical_bytes, allocated_bytes, outcome, detail):
    if action not in {"trash_move", "restore", "trash_purge"}:
        fail("unknown file operation")
    if entry_type not in {"file", "directory"}:
        fail("file operation type must be file or directory")
    if outcome not in {"success", "failed", "skipped"}:
        fail("file operation outcome must be success, failed, or skipped")
    try:
        logical_bytes = int(logical_bytes)
        allocated_bytes = int(allocated_bytes)
    except ValueError:
        fail("file operation sizes must be whole numbers")
    if logical_bytes < 0 or allocated_bytes < 0:
        fail("file operation sizes cannot be negative")
    check_parent(path)
    check_database(path)
    conn = connect(path)
    conn.execute(
        """INSERT INTO file_operation_audit
           (occurred_at, actor_user, actor_uid, action, original_path, entry_type,
            logical_size_bytes, allocated_size_bytes, outcome, detail)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (timestamp(), os.environ.get("USER") or str(os.geteuid()), os.geteuid(), action,
         original_path, entry_type, logical_bytes, allocated_bytes, outcome, detail),
    )
    conn.commit()
    conn.close()


def cmd_operation_list(path, limit=100):
    if not 1 <= limit <= 10000:
        fail("operation-log limit must be between 1 and 10000")
    check_parent(path)
    check_database(path)
    conn = connect(path)
    rows = conn.execute(
        """SELECT occurred_at, actor_user, actor_uid, action, outcome, entry_type,
                  logical_size_bytes, allocated_size_bytes, original_path, detail
           FROM file_operation_audit ORDER BY id DESC LIMIT ?""", (limit,)
    ).fetchall()
    total = conn.execute("SELECT COUNT(*) FROM file_operation_audit").fetchone()[0]
    conn.close()
    print("Wombat Trash audit log — newest first")
    if not rows:
        print("  No Wombat Trash actions have been recorded yet.")
        return
    print(f"  Showing {len(rows):,} of {total:,} recorded actions.")
    print(f"  {'When':<18}{'User':<14}{'Action':<13}{'Result':<9}{'Logical':>12}  {'On disk':>12}  Path")
    for occurred_at, user, uid, action, outcome, entry_type, logical, allocated, original_path, detail in rows:
        when = (occurred_at or "unknown").replace("T", " ")[:16]
        display_path = original_path if len(original_path) <= 52 else "..." + original_path[-49:]
        print(f"  {when:<18}{(user + '/' + str(uid)):<14}{action:<13}{outcome:<9}{human_bytes(logical or 0):>12}  {human_bytes(allocated or 0):>12}  {display_path}")
        if detail and outcome != "success":
            print(f"  {'':<66}Detail: {detail}")


def cmd_set_encryption(path, directory, scope):
    if scope not in {"self", "descendants"}:
        fail("encryption scope must be self or descendants")
    check_parent(path)
    check_database(path)
    directory = os.path.realpath(directory)
    conn = connect(path)
    conn.execute("INSERT INTO path_encryption_labels (path, applies_to_descendants, updated_at) VALUES (?, ?, ?) "
                 "ON CONFLICT(path) DO UPDATE SET applies_to_descendants=excluded.applies_to_descendants, updated_at=excluded.updated_at",
                 (directory, 1 if scope == "descendants" else 0, timestamp()))
    conn.commit(); conn.close()
    print(f"Encryption label saved: {directory} ({scope})")


def cmd_remove_encryption(path, directory):
    check_parent(path)
    check_database(path)
    directory = os.path.realpath(directory)
    conn = connect(path)
    removed = conn.execute("DELETE FROM path_encryption_labels WHERE path=?", (directory,)).rowcount
    conn.commit(); conn.close()
    print(f"Encryption label {'removed' if removed else 'not found'}: {directory}")


def cmd_list_encryption(path):
    check_parent(path)
    check_database(path)
    conn = connect(path)
    output = sys.stdout.buffer
    for label_path, descendants in conn.execute("SELECT path, applies_to_descendants FROM path_encryption_labels ORDER BY path"):
        for value in (label_path, str(descendants)):
            output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    conn.close()


def cmd_list_mounts(_path):
    """Format real data filesystem mount points for the Walker Utilities menu."""
    try:
        result = subprocess.run(
            ["findmnt", "--json", "-t", "ext4,xfs,btrfs,vfat,exfat,ntfs,ntfs3,fuseblk,nfs,nfs4,cifs",
             "-o", "TARGET,SOURCE,FSTYPE,UUID,LABEL,FSROOT"],
            check=True, capture_output=True, text=True,
        )
        mount_tree = json.loads(result.stdout).get("filesystems", [])
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        fail(f"could not read the system mount table: {exc}")

    def clipped(value, width):
        value = value or "-"
        return value if len(value) <= width else value[:width - 3] + "..."

    def flatten(nodes):
        for node in nodes:
            yield node
            yield from flatten(node.get("children", []))

    def filesystem_usage(target):
        """Return live df figures for one mounted filesystem without failing the mount list."""
        try:
            result = subprocess.run(
                ["df", "-B1", "--output=size,used,avail,pcent", target],
                check=True, capture_output=True, text=True,
            )
            fields = result.stdout.splitlines()[-1].split()
            if len(fields) != 4:
                return None
            total, used, available = (int(fields[0]), int(fields[1]), int(fields[2]))
            return total, used, available, fields[3]
        except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
            return None

    def source_device_kind(source):
        """Describe the backing block device when the mount source is a local /dev path."""
        if not source or not source.startswith("/dev/"):
            return "Other source"
        device_name = os.path.basename(source)

        def path_fallback():
            if re.fullmatch(r"(?:nvme\d+n\d+p\d+|mmcblk\d+p\d+|(?:sd|vd|xvd|hd)[a-z]+\d+)", device_name):
                return "Partition"
            if re.fullmatch(r"(?:nvme\d+n\d+|mmcblk\d+|(?:sd|vd|xvd|hd)[a-z]+)", device_name):
                return "Disk"
            return "Device type unavailable"
        try:
            result = subprocess.run(
                ["lsblk", "-no", "TYPE", source],
                check=True, capture_output=True, text=True,
            )
            kind = result.stdout.splitlines()[0].strip().lower()
        except (OSError, subprocess.CalledProcessError, IndexError):
            return path_fallback()
        labels = {
            "part": "Partition",
            "disk": "Disk",
            "lvm": "Logical volume",
            "crypt": "Encrypted mapping",
            "loop": "Loop device",
            "rom": "Optical device",
        }
        return labels.get(kind, kind or path_fallback())

    # `findmnt --json` represents nested mount points as children.  Keep only a
    # filesystem's real root, which removes bind mounts such as /tmp and the
    # repository sandbox while retaining genuine disks and network mounts.
    mounts = [mount for mount in flatten(mount_tree) if mount.get("fsroot") == "/"]
    print(f"{'Mount path':<40}  {'Device/source':<20}  {'Type':<8}  {'UUID':<37}  Label")
    print("=" * 132)
    for mount in mounts:
        target = mount.get("target")
        source = mount.get("source")
        print(f"{clipped(target, 40):<40}  {clipped(mount.get('source'), 20):<20}  {clipped(mount.get('fstype'), 8):<8}  {clipped(mount.get('uuid'), 37):<37}  {mount.get('label') or '-'}")
        usage = filesystem_usage(target)
        device_kind = source_device_kind(source)
        if usage:
            total, used, available, percent = usage
            print(f"Total size: {human_bytes(total):<12}  Used: {human_bytes(used):<12}  Free: {human_bytes(available):<12}  Used %: {percent:<5}  Device: {device_kind}")
        else:
            print(f"Total size: unavailable    Used: unavailable    Free: unavailable    Used %: unavailable    Device: {device_kind}")
        print()


def docker_size_bytes(value):
    if not value:
        return 0
    match = re.fullmatch(r"\s*([0-9.]+)\s*([kMGTPE]?i?B)\s*", value)
    if not match:
        return 0
    number, unit = match.groups()
    factors = {
        "B": 1, "kB": 1000, "KB": 1000, "MB": 1000**2, "GB": 1000**3,
        "TB": 1000**4, "PB": 1000**5, "KiB": 1024, "MiB": 1024**2,
        "GiB": 1024**3, "TiB": 1024**4, "PiB": 1024**5,
    }
    return int(float(number) * factors.get(unit, 0))


def cmd_docker_inventory(path):
    """Record live Docker containers and mounts without changing Docker state."""
    check_parent(path)
    check_database(path)
    try:
        result = subprocess.run(
            ["docker", "ps", "-a", "--size", "--format", "{{json .}}"],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not read Docker inventory: {exc}")
    containers = []
    for line in result.stdout.splitlines():
        try:
            containers.append(json.loads(line))
        except json.JSONDecodeError as exc:
            fail(f"Docker returned invalid container inventory: {exc}")

    now = timestamp()
    conn = connect(path)
    try:
        conn.execute("BEGIN")
        conn.execute("UPDATE docker_containers SET is_stale=1")
        mount_count = 0
        for container in containers:
            container_id = container.get("ID")
            if not container_id:
                continue
            try:
                details_result = subprocess.run(
                    ["docker", "inspect", container_id], check=True, capture_output=True, text=True,
                )
                details = json.loads(details_result.stdout)[0]
            except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, IndexError) as exc:
                raise DatabaseError(f"could not inspect Docker container {container_id}: {exc}") from exc
            size_text = container.get("Size", "")
            size_match = re.fullmatch(r"\s*(.*?)\s*\(virtual\s+(.*?)\)\s*", size_text)
            writable = docker_size_bytes(size_match.group(1) if size_match else size_text)
            virtual = docker_size_bytes(size_match.group(2) if size_match else "")
            labels = details.get("Config", {}).get("Labels") or {}
            conn.execute(
                """INSERT INTO docker_containers
                   (container_id,name,image,status,writable_size_bytes,virtual_size_bytes,created_at,labels_json,first_seen_at,last_seen_at,last_inventory_at,is_stale)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
                   ON CONFLICT(container_id) DO UPDATE SET
                     name=excluded.name,image=excluded.image,status=excluded.status,
                     writable_size_bytes=excluded.writable_size_bytes,virtual_size_bytes=excluded.virtual_size_bytes,
                     created_at=excluded.created_at,labels_json=excluded.labels_json,last_seen_at=excluded.last_seen_at,
                     last_inventory_at=excluded.last_inventory_at,is_stale=0""",
                (container_id, container.get("Names") or container_id, container.get("Image"), container.get("Status"),
                 writable, virtual, details.get("Created"), json.dumps(labels, sort_keys=True), now, now, now),
            )
            container_row_id = conn.execute("SELECT id FROM docker_containers WHERE container_id=?", (container_id,)).fetchone()[0]
            conn.execute("DELETE FROM docker_mounts WHERE container_row_id=?", (container_row_id,))
            for mount in details.get("Mounts") or []:
                conn.execute(
                    """INSERT INTO docker_mounts
                       (container_row_id,mount_type,volume_name,host_source,container_destination,read_write,last_seen_at)
                       VALUES (?,?,?,?,?,?,?)""",
                    (container_row_id, mount.get("Type") or "unknown", mount.get("Name"), mount.get("Source"),
                     mount.get("Destination") or "", int(bool(mount.get("RW"))), now),
                )
                mount_count += 1
        stale_count = conn.execute("SELECT COUNT(*) FROM docker_containers WHERE is_stale=1").fetchone()[0]
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    print(f"Docker inventory refreshed: {len(containers):,} containers, {mount_count:,} mounts, {stale_count:,} stale cached containers")


DOCKER_SCAN_SCRIPT = r'''
walk() {
    current=$1
    [ "$current" = "/" ] || current=${current%/}
    case "$current" in
        /proc|/proc/*|/sys|/sys/*|/dev|/dev/*) return 0 ;;
    esac
    if [ -L "$current" ]; then kind=symlink
    elif [ -d "$current" ]; then kind=directory
    elif [ -f "$current" ]; then kind=file
    else kind=other
    fi
    set -- $(stat -c "%s %b %Y" -- "$current" 2>/dev/null || echo "0 0 0")
    printf "%s\0%s\0%s\0%s\0%s\0" "$kind" "$current" "$1" "$(( $2 * 512 ))" "$3"
    [ "$kind" = directory ] || return 0
    if [ "$current" = "/" ]; then prefix=""; else prefix=$current; fi
    for child in "$prefix"/* "$prefix"/.[!.]* "$prefix"/..?*; do
        [ -e "$child" ] || [ -L "$child" ] || continue
        walk "$child"
    done
}
[ -d "$1" ] || exit 20
walk "$1"
'''


def mount_for_container_path(mounts, container_path):
    matching = []
    for mount_id, destination, volume_name in mounts:
        if destination == "/" or container_path == destination or container_path.startswith(destination.rstrip("/") + "/"):
            matching.append((len(destination), mount_id, volume_name))
    if not matching:
        return None, None
    _, mount_id, volume_name = max(matching)
    return mount_id, volume_name


def progress_line(label, entries, errors, started, expected_entries=None):
    """A deliberately conservative ETA based only on a prior saved inventory."""
    elapsed = max(time.monotonic() - started, 0.01)
    rate = entries / elapsed
    message = (f"{label}: {entries:,} entries  |  {errors:,} errors  |  "
               f"{format_duration(int(elapsed))} elapsed  |  {rate:,.0f}/sec")
    if expected_entries and expected_entries > entries and rate > 0:
        percent = min(99, int(entries * 100 / expected_entries))
        remaining = int((expected_entries - entries) / rate)
        message += (f"  |  {percent}% done, {100 - percent}% remaining  |  "
                    f"ETA about {format_duration(remaining)} (based on previous scan)")
    elif expected_entries:
        message += "  |  Nearly complete (previous scan size reached)"
    else:
        message += "  |  ETA unavailable on a first scan"
    return message


def display_progress(message, active):
    # Some SSH/AI terminal wrappers claim to be a TTY but do not honour carriage returns; their
    # transcript becomes one unreadable concatenated progress line.  Keep the portable default to
    # one start line plus the final summary.  A known-good terminal can opt into live counters.
    if os.environ.get("WOMBAT_WALKER_LIVE_PROGRESS") == "on" and sys.stderr.isatty():
        sys.stderr.write("\r" + message.ljust(132))
        sys.stderr.flush()
        return True
    if not active:
        print(message, file=sys.stderr, flush=True)
    return True


def cmd_docker_scan(path, container_id, container_path):
    check_parent(path)
    check_database(path)
    if not container_path.startswith("/"):
        fail("Docker scan path must be absolute inside the container")
    conn = connect(path)
    container = conn.execute(
        "SELECT id, name, is_stale, writable_size_bytes, virtual_size_bytes FROM docker_containers WHERE container_id=?", (container_id,)
    ).fetchone()
    if not container:
        conn.close()
        fail("container is not in Walker's Docker inventory; refresh Docker workspace first")
    container_row_id, container_name, is_stale, writable_size, virtual_size = container
    if is_stale:
        conn.close()
        fail("container is stale; refresh Docker workspace and select a live container")
    mounts = conn.execute(
        "SELECT id, container_destination, volume_name FROM docker_mounts WHERE container_row_id=?", (container_row_id,)
    ).fetchall()
    previous_scan = conn.execute(
        """SELECT entry_count FROM docker_scan_runs
           WHERE container_row_id=? AND scanned_path=? AND status='complete' AND entry_count IS NOT NULL
           ORDER BY finished_at DESC LIMIT 1""",
        (container_row_id, container_path),
    ).fetchone()
    expected_entries = previous_scan[0] if previous_scan else None
    print(f"Docker scan starting: {container_name} {container_path}")
    print(f"  Docker-reported size: writable {human_bytes(writable_size or 0)}  |  virtual {human_bytes(virtual_size or 0)}")
    print("  Note: virtual size includes the image layers; scan time depends mostly on the number of files and folders.")
    now = timestamp()
    run_id = conn.execute(
        "INSERT INTO docker_scan_runs (container_row_id,scope,scanned_path,started_at,status) VALUES (?, 'container', ?, ?, 'running')",
        (container_row_id, container_path, now),
    ).lastrowid
    conn.commit()
    try:
        process = subprocess.Popen(
            ["docker", "exec", "-u", "0", container_id, "/bin/sh", "-c", DOCKER_SCAN_SCRIPT, "wombat-walker", container_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError as exc:
        conn.execute("UPDATE docker_scan_runs SET finished_at=?, status='failed', error_count=1 WHERE id=?", (timestamp(), run_id))
        conn.commit(); conn.close()
        fail(f"could not start Docker scan: {exc}")
    output_queue = queue.Queue()

    def collect_output(kind, stream):
        try:
            while True:
                chunk = stream.read(65536)
                if not chunk:
                    break
                output_queue.put((kind, chunk))
        finally:
            output_queue.put((kind, None))

    readers = [
        threading.Thread(target=collect_output, args=("stdout", process.stdout), daemon=True),
        threading.Thread(target=collect_output, args=("stderr", process.stderr), daemon=True),
    ]
    for reader in readers:
        reader.start()
    fields = []
    field_remainder = b""
    stderr_chunks = []
    streams_closed = 0
    started = time.monotonic()
    last_progress = started
    progress_active = False
    progress_active = display_progress(
        progress_line("Scanning Docker", 0, 0, started, expected_entries), progress_active
    )
    while streams_closed < 2:
        try:
            kind, chunk = output_queue.get(timeout=1)
        except queue.Empty:
            progress_active = display_progress(
                progress_line("Scanning Docker", len(fields) // 5, 0, started, expected_entries), progress_active
            )
            last_progress = time.monotonic()
            continue
        if chunk is None:
            streams_closed += 1
            continue
        if kind == "stderr":
            stderr_chunks.append(chunk)
            continue
        field_remainder += chunk
        parts = field_remainder.split(b"\0")
        field_remainder = parts.pop()
        fields.extend(parts)
        now_monotonic = time.monotonic()
        if now_monotonic - last_progress >= 1:
            progress_active = display_progress(
                progress_line("Scanning Docker", len(fields) // 5, 0, started, expected_entries), progress_active
            )
            last_progress = now_monotonic
    process.wait()
    if field_remainder:
        fields.append(field_remainder)
    if progress_active:
        print(file=sys.stderr)
    if len(fields) % 5:
        conn.execute("UPDATE docker_scan_runs SET finished_at=?, status='failed', error_count=1 WHERE id=?", (timestamp(), run_id))
        conn.commit(); conn.close()
        fail("Docker scan returned malformed metadata")
    rows = []
    fts_rows = []
    for index in range(0, len(fields), 5):
        entry_type, entry_path, logical_size, allocated_size, mtime_ns = (
            field.decode("utf-8", "surrogateescape") for field in fields[index:index + 5]
        )
        if entry_type not in {"file", "directory", "symlink", "other"} or not entry_path.startswith("/"):
            continue
        try:
            logical_size = int(logical_size)
            allocated_size = int(allocated_size)
            mtime_ns = int(mtime_ns) * 1_000_000_000
        except ValueError:
            continue
        mount_id, volume_name = mount_for_container_path(mounts, entry_path)
        relative_path = entry_path[len(container_path):].lstrip("/") if entry_path.startswith(container_path.rstrip("/") + "/") else ""
        rows.append((run_id, container_row_id, mount_id, entry_path, relative_path, os.path.basename(entry_path.rstrip("/")) or "/", entry_type, logical_size, allocated_size, mtime_ns, volume_name))
    status = "complete" if process.returncode == 0 else "incomplete"
    error_count = 0 if status == "complete" else 1
    try:
        subtree_prefix = container_path.rstrip("/") + "/"
        path_filter = "container_path=? OR substr(container_path, 1, length(?))=?"
        path_args = (container_row_id, container_path, subtree_prefix, subtree_prefix)
        conn.execute(
            "DELETE FROM docker_path_search WHERE entry_id IN (SELECT id FROM docker_path_entries WHERE container_row_id=? AND (" + path_filter + "))",
            path_args,
        )
        conn.execute("DELETE FROM docker_path_entries WHERE container_row_id=? AND (" + path_filter + ")", path_args)
        for row in rows:
            entry_cursor = conn.execute(
                """INSERT INTO docker_path_entries
                   (scan_id,container_row_id,mount_id,container_path,relative_path,basename,entry_type,logical_size_bytes,allocated_size_bytes,mtime_ns)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""", row[:-1],
            )
            fts_rows.append((row[3], row[5], container_name, row[-1] or "", entry_cursor.lastrowid))
        conn.executemany(
            "INSERT INTO docker_path_search (container_path,basename,container_name,volume_name,entry_id) VALUES (?,?,?,?,?)", fts_rows,
        )
        conn.execute(
            "UPDATE docker_scan_runs SET finished_at=?, status=?, entry_count=?, error_count=? WHERE id=?",
            (timestamp(), status, len(rows), error_count, run_id),
        )
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    elapsed_seconds = max(time.monotonic() - started, 0.01)
    print(f"Docker scan {status}: {container_name} {container_path}")
    print(f"  Docker-reported size: writable {human_bytes(writable_size or 0)}  |  virtual {human_bytes(virtual_size or 0)}")
    print(f"  Entries saved: {len(rows):,}")
    print(f"  Time taken: {format_duration(int(elapsed_seconds))}")
    print(f"  Average metadata-save rate: {len(rows) / elapsed_seconds:,.0f} entries/sec")
    if status == "incomplete":
        error = b"".join(stderr_chunks).decode("utf-8", "replace").strip() or "container command exited non-zero"
        print(f"  Warning: {error}")


def cmd_docker_session_summary(path, started_at):
    """Print totals for the current explicit all-container scan session."""
    check_parent(path)
    check_database(path)
    conn = connect(path)
    try:
        summary = conn.execute(
            """SELECT COUNT(*), COALESCE(SUM(entry_count), 0), COALESCE(SUM(error_count), 0),
                      MIN(started_at), MAX(finished_at)
               FROM docker_scan_runs WHERE started_at >= ?""",
            (started_at,),
        ).fetchone()
    finally:
        conn.close()
    scan_count, entry_count, error_count, first_started, last_finished = summary
    if not scan_count:
        print("No Docker scans were saved in this session.")
        return
    try:
        elapsed = max((datetime.fromisoformat(last_finished).timestamp() - datetime.fromisoformat(first_started).timestamp()), 0.01)
    except (TypeError, ValueError):
        elapsed = 0.01
    print("================== All-container scan totals ==================")
    print(f"  Containers scanned: {scan_count:,}")
    print(f"  Total entries saved: {entry_count:,}")
    print(f"  Total time elapsed: {format_duration(int(elapsed))}")
    print(f"  Average metadata-save rate: {entry_count / elapsed:,.0f} entries/sec")
    print(f"  Scan errors: {error_count:,}")


def cmd_docker_folder_total(path, container_id, container_path):
    """Return cached file-data totals only when a completed scan covers this folder."""
    check_parent(path)
    check_database(path)
    if not container_path.startswith("/"):
        fail("Docker folder path must be absolute")
    conn = connect(path)
    try:
        container = conn.execute("SELECT id FROM docker_containers WHERE container_id=? AND is_stale=0", (container_id,)).fetchone()
        if not container:
            fail("container is not in the current Docker inventory")
        container_row_id = container[0]
        coverage = conn.execute(
            """SELECT scanned_path, finished_at FROM docker_scan_runs
               WHERE container_row_id=? AND status='complete' AND finished_at IS NOT NULL
                 AND (scanned_path='/' OR ?=scanned_path OR ? LIKE scanned_path || '/%')
               ORDER BY length(scanned_path) DESC, finished_at DESC LIMIT 1""",
            (container_row_id, container_path, container_path),
        ).fetchone()
        if not coverage:
            return
        upper_bound = container_path.rstrip("/") + "/" if container_path != "/" else "/"
        upper_bound += chr(0x10FFFF)
        logical, allocated, files = conn.execute(
            """SELECT COALESCE(SUM(logical_size_bytes), 0), COALESCE(SUM(allocated_size_bytes), 0), COUNT(*)
               FROM docker_path_entries
               WHERE container_row_id=? AND entry_type='file'
                 AND container_path >= ? AND container_path < ?""",
            (container_row_id, container_path, upper_bound),
        ).fetchone()
        output = sys.stdout.buffer
        for value in (logical, allocated, files, coverage[0], coverage[1]):
            output.write(str(value).encode("utf-8", "surrogateescape") + b"\0")
    finally:
        conn.close()


def search_order_sql(order, table="entries", fts_table=None):
    orders = {
        "relevance": f"bm25({fts_table}), {table}.container_path" if fts_table else f"bm25(path_search), {table}.path",
        "largest": f"COALESCE({table}.logical_size_bytes, 0) DESC, {table}.container_path" if fts_table else f"COALESCE({table}.logical_size_bytes, 0) DESC, {table}.path",
        "smallest": f"COALESCE({table}.logical_size_bytes, 0), {table}.container_path" if fts_table else f"COALESCE({table}.logical_size_bytes, 0), {table}.path",
        "updated": f"COALESCE({table}.mtime_ns, 0) DESC, {table}.container_path" if fts_table else f"COALESCE({table}.mtime_ns, 0) DESC, {table}.path",
    }
    if order not in orders:
        fail("search order must be relevance, largest, smallest, or updated")
    return orders[order]


def docker_search_rows(conn, words, limit, offset=0, container_id=None, path_prefix=None, order="relevance", min_size=None, max_size=None):
    tokens = search_tokens(words)
    query = fts_query(tokens)
    sql = """
        FROM docker_path_search
        JOIN docker_path_entries AS entries ON entries.id = CAST(docker_path_search.entry_id AS INTEGER)
        JOIN docker_containers AS containers ON containers.id = entries.container_row_id
        JOIN docker_scan_runs AS runs ON runs.id = entries.scan_id
        LEFT JOIN docker_mounts AS mounts ON mounts.id = entries.mount_id
        WHERE docker_path_search MATCH ? AND containers.is_stale=0
    """
    args = [query]
    if container_id:
        sql += " AND containers.container_id=?"
        args.append(container_id)
    if min_size is not None:
        sql += " AND COALESCE(entries.logical_size_bytes, 0)>=?"
        args.append(min_size)
    if max_size is not None:
        sql += " AND COALESCE(entries.logical_size_bytes, 0)<=?"
        args.append(max_size)
    if path_prefix:
        prefix = path_prefix.rstrip("/") + "/" if path_prefix != "/" else "/"
        sql += " AND (entries.container_path=? OR substr(entries.container_path, 1, length(?))=?)"
        args.extend((path_prefix, prefix, prefix))
    # Match ordinary word searches against the filename itself. A slash explicitly requests a
    # path search, which is useful when the parent directory is the meaningful term.
    if "/" not in words:
        for token in tokens:
            sql += " AND entries.basename LIKE ?"
            args.append(f"%{token}%")
    total = conn.execute("SELECT COUNT(*) " + sql, args).fetchone()[0]
    rows = conn.execute(
        """SELECT containers.container_id, containers.name, entries.entry_type, entries.logical_size_bytes,
                  entries.allocated_size_bytes, entries.mtime_ns, entries.container_path,
                  mounts.mount_type, mounts.volume_name, runs.finished_at, runs.status
           """ + sql + f" ORDER BY {search_order_sql(order, fts_table='docker_path_search')} LIMIT ? OFFSET ?", [*args, limit, offset],
    ).fetchall()
    return rows, total


def docker_container_runs_as(container_id):
    """Return the configured Docker user for display; an empty value uses the image default."""
    try:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{.Config.User}}", container_id],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip() or "image default"


def cmd_docker_search(path, words, limit, offset=0, container_id=None, path_prefix=None, order="relevance", min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if not 1 <= limit <= 10000:
        fail("Docker search limit must be between 1 and 10000")
    conn = connect(path)
    rows, total = docker_search_rows(conn, words, limit, offset, container_id, path_prefix, order, min_size, max_size)
    if not rows:
        print(f"No saved Docker paths match: {words!r}")
        conn.close(); return
    print()
    print("=" * 114)
    print(f"Docker search: {words!r}")
    if path_prefix:
        print(f"Scope: container folder {path_prefix}")
    elif container_id:
        print("Scope: current container")
    else:
        print("Scope: all saved Docker containers")
    print(f"Found {total:,} matching saved paths. Order: {order}. Stale container inventories are hidden.")
    last_group = None
    for number, row in enumerate(rows, offset + 1):
        container_id, container_name, entry_type, logical, allocated, mtime_ns, entry_path, mount_type, volume_name, finished_at, status = row
        storage = volume_name or (mount_type or "container layer")
        group = (container_id, storage, finished_at, status)
        if group != last_group:
            if last_group is not None:
                print()
            print("=" * 114)
            print(f"Container: {container_name}    Storage: {storage}")
            print(f"Saved scan: {finished_at or 'unknown'} ({status})")
            print()
            runs_as = docker_container_runs_as(container_id)
            print(f"{'No.':<5}{'Type':<10}{'Runs as':<16}{'Logical':>12}  {'On disk':>12}  Path")
            last_group = group
        print(f"[{number}]".ljust(5) + f"{entry_type:<10}{runs_as:<16}{human_bytes(logical or 0):>12}  {human_bytes(allocated or 0):>12}  {entry_path}")
    if total > offset + len(rows):
        print(f"\nShowing {offset + 1:,}-{offset + len(rows):,} of {total:,} results.")
    conn.close()


def cmd_docker_search_path(path, words, number, container_id=None, path_prefix=None, order="relevance", min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if number < 1:
        fail("Docker search result number must be positive")
    conn = connect(path)
    rows, total = docker_search_rows(conn, words, 1, number - 1, container_id, path_prefix, order, min_size, max_size)
    if number > total or not rows:
        conn.close()
        fail("Docker search result number is outside the displayed results")
    container_id, container_name, entry_type, _, _, _, entry_path, *_ = rows[0]
    output = sys.stdout.buffer
    for value in (container_id, container_name, entry_type, entry_path):
        output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    conn.close()


def combined_search_rows(conn, words, limit, offset=0, order="relevance", min_size=None, max_size=None):
    # Fetch enough top records from each independently indexed source to make the combined page
    # exact. A global page starting at offset N cannot contain an item ranked below N in either
    # source, so limit + offset from each source is sufficient.
    fetch_limit = min(10000, limit + offset)
    host_rows, _, host_total = search_rows(conn, words, "-", fetch_limit, 0, None, order, False, min_size, max_size)
    docker_rows, docker_total = docker_search_rows(conn, words, fetch_limit, 0, None, None, order, min_size, max_size)
    rows = []
    for entry_type, logical, mtime_ns, entry_path, root_path, status, scanned_at in host_rows:
        rows.append(("host", entry_type, logical or 0, mtime_ns or 0, root_path, entry_path, "", "", status, scanned_at))
    for container_id, container_name, entry_type, logical, _allocated, mtime_ns, entry_path, _mount_type, _volume_name, scanned_at, status in docker_rows:
        rows.append(("docker", entry_type, logical or 0, mtime_ns or 0, container_name, entry_path, container_id, container_name, status, scanned_at))
    if order == "largest":
        rows.sort(key=lambda row: (-row[2], row[5]))
    elif order == "smallest":
        rows.sort(key=lambda row: (row[2], row[5]))
    elif order == "updated":
        rows.sort(key=lambda row: (-row[3], row[5]))
    else:
        # Full-text relevance is calculated separately by SQLite's two FTS indexes, so there is
        # no meaningful cross-index score. The combined default is a predictable path ordering.
        rows.sort(key=lambda row: (row[4].casefold(), row[5].casefold()))
    return rows[offset:offset + limit], host_total + docker_total


def cmd_combined_search(path, words, limit, offset=0, order="relevance", min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if not 1 <= limit <= 10000:
        fail("search limit must be between 1 and 10000")
    if offset < 0:
        fail("search offset cannot be negative")
    conn = connect(path)
    rows, total = combined_search_rows(conn, words, limit, offset, order, min_size, max_size)
    order_label = "alphabetical" if order == "relevance" else order
    filters = []
    if min_size is not None: filters.append(f"minimum size {human_bytes(min_size)}")
    if max_size is not None: filters.append(f"maximum size {human_bytes(max_size)}")
    filter_label = f"    Filters: {', '.join(filters)}" if filters else ""
    print(f"Combined search: {words!r}    Scope: saved filesystem + saved Docker scans    Order: {order_label}{filter_label}")
    if not rows:
        print("No matching cached paths.")
        conn.close()
        return
    print(f"Found {total:,} matching cached results.")
    print(f"{'No.':<5}{'Source':<36}{'Type':<10} {'Size':>12}  {'Last modified':<16}  Name")
    for number, row in enumerate(rows, start=offset + 1):
        source, entry_type, logical, mtime_ns, location, entry_path, _container_id, _container_name, _status, _scanned_at = row
        source_label = "host: " + location if source == "host" else "Docker: " + location
        name = os.path.basename(entry_path.rstrip("/")) or "/"
        display_name = name if len(name) <= 42 else name[:39] + "..."
        print(f"[{number}]".ljust(5) + f"{source_label:<36}{entry_type:<10} {human_bytes(logical):>12}  {format_time(mtime_ns):<16}  {display_name}")
        print(" " * 5 + entry_path)
    print(f"\nShowing {offset + 1:,}-{offset + len(rows):,} of {total:,} matching results.")
    conn.close()


def cmd_combined_search_path(path, words, number, order="relevance", min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if number < 1 or number > 10000:
        fail("search result number must be between 1 and 10000")
    conn = connect(path)
    rows, _ = combined_search_rows(conn, words, number, 0, order, min_size, max_size)
    if len(rows) < number:
        conn.close()
        fail("search result number is outside the result list")
    source, entry_type, _logical, _mtime_ns, location, entry_path, container_id, container_name, _status, _scanned_at = rows[number - 1]
    if source == "host":
        entry_path = filesystem_path_text(entry_path)
    output = sys.stdout.buffer
    for value in (source, container_id, container_name or location, entry_type, entry_path):
        output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    conn.close()


def search_tokens(words):
    tokens = re.findall(r"[^\W_]+", words, flags=re.UNICODE)
    if not tokens:
        fail("search needs at least one letter or number")
    return tokens


def fts_query(tokens):
    # Search text is never SQL: each token becomes a quoted FTS prefix and MATCH receives it as
    # a parameter.
    return " AND ".join('"' + token.replace('"', '""') + '"*' for token in tokens)


def search_rows(conn, words, root, limit, offset=0, path_prefix=None, order="relevance", direct_only=False, min_size=None, max_size=None):
    root_id = None
    if root != "-":
        row = conn.execute("SELECT id FROM scan_roots WHERE root_path=?", (root,)).fetchone()
        if not row:
            fail(f"no saved scan exists for root: {root}")
        root_id = row[0]
    sql = """
        FROM path_search
        JOIN path_entries AS entries ON entries.id = CAST(path_search.entry_id AS INTEGER)
        JOIN scan_roots AS roots ON roots.id = entries.root_id
        WHERE path_search MATCH ?
    """
    tokens = search_tokens(words)
    args = [fts_query(tokens)]
    # A slash means the user is deliberately searching a path (for example, etc/shadow). For
    # ordinary word searches, require every word in the actual filename rather than matching
    # words split across unrelated parent directories.
    if "/" not in words:
        for token in tokens:
            sql += " AND entries.basename LIKE ?"
            args.append(f"%{token}%")
    if root_id is not None:
        sql += " AND entries.root_id=?"
        args.append(root_id)
    if min_size is not None:
        sql += " AND COALESCE(entries.logical_size_bytes, 0)>=?"
        args.append(min_size)
    if max_size is not None:
        sql += " AND COALESCE(entries.logical_size_bytes, 0)<=?"
        args.append(max_size)
    if path_prefix:
        path_prefix = database_path_text(os.path.realpath(path_prefix))
        if direct_only and path_prefix == "/":
            sql += " AND entries.path LIKE '/%' AND instr(substr(entries.path, 2), '/')=0"
        elif direct_only:
            sql += " AND substr(entries.path, 1, length(?)+1)=? || '/' AND instr(substr(entries.path, length(?)+2), '/')=0"
            args.extend([path_prefix, path_prefix, path_prefix])
        elif path_prefix == "/":
            # The normal descendant expression appends '/', which would turn the root prefix
            # into '//' and exclude every absolute path.
            sql += " AND entries.path LIKE '/%'"
        else:
            sql += " AND (entries.path=? OR substr(entries.path, 1, length(?)+1)=? || '/')"
            args.extend([path_prefix, path_prefix, path_prefix])
    total = conn.execute("SELECT COUNT(*) " + sql, args).fetchone()[0]
    query = """
        SELECT entries.entry_type, entries.logical_size_bytes, entries.mtime_ns, entries.path,
               roots.root_path, roots.last_status, roots.last_full_scan_at
    """ + sql + f" ORDER BY {search_order_sql(order)} LIMIT ? OFFSET ?"
    rows = conn.execute(query, [*args, limit, offset]).fetchall()
    return rows, root_id, total


def cmd_search(path, words, root, limit, offset=0, path_prefix=None, order="relevance", direct_only=False, min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if not 1 <= limit <= 10000:
        fail("search limit must be between 1 and 10000")
    if offset < 0:
        fail("search offset cannot be negative")
    conn = connect(path)
    rows, root_id, total = search_rows(conn, words, root, limit, offset, path_prefix, order, direct_only, min_size, max_size)
    scope = root if root_id is not None else "all saved scans"
    if path_prefix:
        relation = " directly in" if direct_only else " below"
        scope += f"{relation} {os.path.realpath(path_prefix)}"
    filters = []
    if min_size is not None: filters.append(f"minimum size {human_bytes(min_size)}")
    if max_size is not None: filters.append(f"maximum size {human_bytes(max_size)}")
    filter_label = f"    Filters: {', '.join(filters)}" if filters else ""
    print(f"Search: {words!r}    Scope: {scope}    Order: {order}{filter_label}")
    if not rows:
        print("No matching cached paths.")
        conn.close()
        return
    print(f"Found {total:,} matching cached result{'s' if total != 1 else ''}.")
    groups = {}
    for number, row in enumerate(rows, start=offset + 1):
        groups.setdefault(row[4], []).append((number, row))
    for root_path, group in groups.items():
        _, first = group[0]
        status, scanned_at = first[5], first[6]
        print()
        print(f"From saved scan of: {root_path}")
        print(f"Scan status: {status or 'unknown'}    Completed: {scanned_at or 'unknown'}")
        print(f"{'No.':<5}{'Type':<10} {'Size':>12}  {'Last modified':<16}  Path")
        for number, (entry_type, size, mtime_ns, entry_path, _, _, _) in group:
            print(f"[{number}]".ljust(5) + f"{entry_type:<10} {human_bytes(size or 0):>12}  {format_time(mtime_ns):<16}  {entry_path}")
    if rows:
        print(f"\nShowing {offset + 1:,}-{offset + len(rows):,} of {total:,} matching results.")
    else:
        print(f"\nShowing 0 of {total:,} matching results.")
    conn.close()


def cmd_search_path(path, words, root, number, path_prefix=None, order="relevance", direct_only=False, min_size=None, max_size=None):
    check_parent(path)
    check_database(path)
    if number < 1 or number > 10000:
        fail("search result number must be between 1 and 10000")
    conn = connect(path)
    rows, _, _ = search_rows(conn, words, root, number, 0, path_prefix, order, direct_only, min_size, max_size)
    if len(rows) < number:
        fail("search result number is outside the result list")
    sys.stdout.buffer.write(filesystem_path_text(rows[number - 1][3]).encode("utf-8", "surrogateescape"))
    sys.stdout.buffer.write(b"\n")
    conn.close()


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def human_bytes(value):
    units = ("B", "KB", "MB", "GB", "TB", "PB")
    value = float(value)
    unit = 0
    while value >= 1000 and unit < len(units) - 1:
        value /= 1000
        unit += 1
    return f"{value:.0f}{units[unit]}" if unit == 0 else f"{value:.2f}{units[unit]}"


def parse_size_filter(value):
    if value in {None, "", "-"}:
        return None
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB|PB|KIB|MIB|GIB|TIB|PIB)?\s*", value, re.IGNORECASE)
    if not match:
        fail("size filters must look like 100MB, 1.5GB, or 5000000B")
    number = float(match.group(1))
    unit = (match.group(2) or "B").upper()
    multipliers = {"B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4, "PB": 1000**5,
                   "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4, "PIB": 1024**5}
    return int(number * multipliers[unit])


def format_time(value):
    if value is None:
        return "?"
    return datetime.fromtimestamp(value / 1_000_000_000, timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")


def format_duration(seconds):
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def database_path_text(value):
    """Store filesystem names as SQLite-safe text without losing surrogateescaped bytes.

    Linux filenames are bytes, not necessarily UTF-8. Python represents an invalid UTF-8 byte
    as a low surrogate; sqlite3 refuses those characters.  Escape only those bytes (and the
    escape marker itself) so ordinary paths remain readable and a selected result can be restored
    to its exact original filesystem name.
    """
    escaped = []
    for character in value:
        codepoint = ord(character)
        if character == "~":
            escaped.append("~~")
        elif 0xDC80 <= codepoint <= 0xDCFF:
            escaped.append(f"~{codepoint - 0xDC00:02X}")
        else:
            escaped.append(character)
    return "".join(escaped)


def filesystem_path_text(value):
    """Turn a database path back into Python's exact filesystem string."""
    restored = []
    index = 0
    while index < len(value):
        if value[index] != "~" or index + 1 >= len(value):
            restored.append(value[index]); index += 1; continue
        if value[index + 1] == "~":
            restored.append("~"); index += 2; continue
        encoded_byte = value[index + 1:index + 3]
        if len(encoded_byte) == 2 and all(character in "0123456789abcdefABCDEF" for character in encoded_byte):
            restored.append(chr(0xDC00 + int(encoded_byte, 16))); index += 3; continue
        restored.append("~"); index += 1
    return "".join(restored)


def entry_values(root_id, scan_id, path, info):
    mode = info.st_mode
    if stat.S_ISDIR(mode):
        kind = "directory"
    elif stat.S_ISLNK(mode):
        kind = "symlink"
    elif stat.S_ISREG(mode):
        kind = "file"
    else:
        kind = "other"
    return (root_id, database_path_text(path), database_path_text(os.path.basename(path)), info.st_dev, info.st_ino, kind, info.st_size,
            getattr(info, "st_blocks", 0) * 512, info.st_mtime_ns, info.st_ctime_ns, scan_id)


def is_within(path, ancestor):
    try:
        return os.path.commonpath((path, ancestor)) == ancestor
    except ValueError:
        return False


def filesystem_identity(target):
    """Return UUID, label, and mount target without relying on a stable mount path."""
    try:
        result = subprocess.run(
            ["findmnt", "--json", "--output", "UUID,LABEL,TARGET", "--target", target],
            check=True, capture_output=True, text=True,
        )
        filesystems = json.loads(result.stdout).get("filesystems", [])
        if filesystems:
            item = filesystems[0]
            mount_path = item.get("target")
            return item.get("uuid"), item.get("label"), os.path.realpath(mount_path) if mount_path else None
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        pass
    return None, None, None


def relocate_saved_root(conn, root_id, old_root, new_root):
    """Move cached absolute paths when the same UUID appears at a new mount point."""
    if old_root == new_root:
        return
    start = len(old_root) + 1
    conn.execute("UPDATE path_entries SET path=? || substr(path, ?) WHERE root_id=?", (new_root, start, root_id))
    conn.execute("UPDATE directory_totals SET path=? || substr(path, ?) WHERE root_id=?", (new_root, start, root_id))
    conn.execute("UPDATE path_encryption_labels SET path=? || substr(path, ?) WHERE path=? OR substr(path, 1, length(?)+1)=? || '/'", (new_root, start, old_root, old_root, old_root))
    conn.execute("UPDATE scan_roots SET root_path=? WHERE id=?", (new_root, root_id))
    conn.execute("DELETE FROM path_search WHERE root_id=?", (root_id,))
    conn.execute("INSERT INTO path_search (path,basename,root_id,entry_id) SELECT path,basename,root_id,id FROM path_entries WHERE root_id=?", (root_id,))


def cmd_scan(path, target, context):
    if context not in {"admin", "little"}:
        fail("scan context must be admin or little")
    target = os.path.realpath(target)
    try:
        target_info = os.lstat(target)
    except OSError as exc:
        fail(f"cannot inspect scan target {target}: {exc}")
    if not stat.S_ISDIR(target_info.st_mode):
        fail("scan target must be a directory")
    cmd_init(path)
    conn = connect(path)
    filesystem_uuid, filesystem_label, mount_path = filesystem_identity(target)
    candidates = conn.execute("SELECT id, root_path FROM scan_roots WHERE device_id=? AND privilege_context=?", (target_info.st_dev, context)).fetchall()
    candidates = [(candidate_id, candidate_path) for candidate_id, candidate_path in candidates if is_within(target, candidate_path)]
    if candidates:
        root_id, root = max(candidates, key=lambda candidate: len(candidate[1]))
        scope = "full" if target == root else "targeted"
    else:
        uuid_candidates = []
        if filesystem_uuid and mount_path:
            for candidate_id, old_root, relative_path in conn.execute("SELECT id, root_path, root_relative_path FROM scan_roots WHERE filesystem_uuid=? AND privilege_context=?", (filesystem_uuid, context)):
                if relative_path is None:
                    continue
                candidate_root = os.path.normpath(os.path.join(mount_path, relative_path))
                if is_within(target, candidate_root):
                    uuid_candidates.append((candidate_id, old_root, candidate_root))
        if uuid_candidates:
            root_id, old_root, root = max(uuid_candidates, key=lambda candidate: len(candidate[2]))
            relocate_saved_root(conn, root_id, old_root, root)
            scope = "full" if target == root else "targeted"
        else:
            root = target
            scope = "full"
            root_relative = os.path.relpath(root, mount_path) if mount_path and is_within(root, mount_path) else "."
            conn.execute("INSERT INTO scan_roots (root_path, device_id, privilege_context, filesystem_uuid, filesystem_label, last_mount_path, root_relative_path) VALUES (?, ?, ?, ?, ?, ?, ?)",
                         (root, target_info.st_dev, context, filesystem_uuid, filesystem_label, mount_path, root_relative))
            root_id = conn.execute("SELECT id FROM scan_roots WHERE root_path=?", (root,)).fetchone()[0]
    root_relative = os.path.relpath(root, mount_path) if mount_path and is_within(root, mount_path) else "."
    conn.execute("UPDATE scan_roots SET device_id=?, filesystem_uuid=?, filesystem_label=?, last_mount_path=?, root_relative_path=? WHERE id=?",
                 (target_info.st_dev, filesystem_uuid, filesystem_label, mount_path, root_relative, root_id))
    previous_scan = conn.execute(
        """SELECT entry_count FROM scan_runs
           WHERE root_id=? AND scanned_path=? AND status='complete' AND entry_count IS NOT NULL
           ORDER BY finished_at DESC LIMIT 1""",
        (root_id, target),
    ).fetchone()
    expected_entries = previous_scan[0] if previous_scan else None
    run_id = conn.execute("INSERT INTO scan_runs (root_id, scope, scanned_path, started_at, status, scanner_version) VALUES (?, ?, ?, ?, 'running', ?)",
                          (root_id, scope, target, timestamp(), "2")).lastrowid
    errors = []
    rows = []
    logical_total = 0
    allocated_total = 0
    visited = 0
    started = time.monotonic()
    last_progress = started
    progress_active = False

    def progress():
        nonlocal progress_active, last_progress
        progress_active = display_progress(
            progress_line("Scanning host files", visited, len(errors), started, expected_entries), progress_active
        )
        last_progress = time.monotonic()

    progress()

    def flush():
        nonlocal rows
        if rows:
            conn.executemany("INSERT INTO path_entries (root_id,path,basename,device_id,inode,entry_type,logical_size_bytes,allocated_size_bytes,mtime_ns,ctime_ns,last_seen_scan_id) "
                             "VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(root_id,path) DO UPDATE SET basename=excluded.basename,device_id=excluded.device_id,inode=excluded.inode,entry_type=excluded.entry_type,logical_size_bytes=excluded.logical_size_bytes,allocated_size_bytes=excluded.allocated_size_bytes,mtime_ns=excluded.mtime_ns,ctime_ns=excluded.ctime_ns,last_seen_scan_id=excluded.last_seen_scan_id", rows)
            rows = []

    def onerror(exc):
        errors.append((run_id, database_path_text(getattr(exc, "filename", target) or target), "walk", database_path_text(str(exc))))

    rows.append(entry_values(root_id, run_id, target, target_info))
    visited = 1
    for base, dirs, files in os.walk(target, topdown=True, followlinks=False, onerror=onerror):
        kept = []
        for name in dirs:
            candidate = os.path.join(base, name)
            try:
                info = os.lstat(candidate)
            except OSError as exc:
                errors.append((run_id, database_path_text(candidate), "lstat", database_path_text(str(exc)))); continue
            if info.st_dev != target_info.st_dev:
                continue
            rows.append(entry_values(root_id, run_id, candidate, info))
            visited += 1
            if not stat.S_ISLNK(info.st_mode):
                kept.append(name)
        dirs[:] = kept
        for name in files:
            candidate = os.path.join(base, name)
            try:
                info = os.lstat(candidate)
            except OSError as exc:
                errors.append((run_id, database_path_text(candidate), "lstat", database_path_text(str(exc)))); continue
            if info.st_dev != target_info.st_dev:
                continue
            rows.append(entry_values(root_id, run_id, candidate, info))
            visited += 1
            if stat.S_ISREG(info.st_mode):
                logical_total += info.st_size
                allocated_total += getattr(info, "st_blocks", 0) * 512
        if len(rows) >= 1000:
            flush()
        if time.monotonic() - last_progress >= 1:
            progress()
    flush()
    if errors:
        conn.executemany("INSERT INTO scan_errors (scan_id,path,operation,error_text) VALUES (?,?,?,?)", errors)
    subtree_condition = "(path=? OR substr(path, 1, length(?)+1)=? || '/')"
    subtree_args = (target, target, target)
    if scope == "full":
        conn.execute("DELETE FROM path_search WHERE root_id=?", (root_id,))
        conn.execute("DELETE FROM path_entries WHERE root_id=? AND last_seen_scan_id<>?", (root_id, run_id))
    else:
        conn.execute(f"DELETE FROM path_search WHERE root_id=? AND {subtree_condition}", (root_id, *subtree_args))
        conn.execute(f"DELETE FROM path_entries WHERE root_id=? AND {subtree_condition} AND last_seen_scan_id<>?", (root_id, *subtree_args, run_id))
    conn.execute("INSERT INTO directory_totals (root_id,path,logical_total_bytes,allocated_total_bytes,newest_mtime_ns,calculated_scan_id) VALUES (?,?,?,?,?,?) "
                 "ON CONFLICT(root_id,path) DO UPDATE SET logical_total_bytes=excluded.logical_total_bytes,allocated_total_bytes=excluded.allocated_total_bytes,calculated_scan_id=excluded.calculated_scan_id",
                 (root_id, target, logical_total, allocated_total, target_info.st_mtime_ns, run_id))
    if scope == "full":
        conn.execute("INSERT INTO path_search (path,basename,root_id,entry_id) SELECT path,basename,root_id,id FROM path_entries WHERE root_id=?", (root_id,))
    else:
        conn.execute(f"INSERT INTO path_search (path,basename,root_id,entry_id) SELECT path,basename,root_id,id FROM path_entries WHERE root_id=? AND {subtree_condition}", (root_id, *subtree_args))
    status = "incomplete" if errors else "complete"
    cached_count = conn.execute("SELECT COUNT(*) FROM path_entries WHERE root_id=?", (root_id,)).fetchone()[0]
    conn.execute("UPDATE scan_runs SET finished_at=?, status=?, entry_count=?, error_count=?, logical_bytes=?, allocated_bytes=? WHERE id=?", (timestamp(), status, visited, len(errors), logical_total, allocated_total, run_id))
    if scope == "full":
        conn.execute("UPDATE scan_roots SET last_full_scan_at=?, last_status=?, totals_stale=0 WHERE id=?", (timestamp(), status, root_id))
    else:
        conn.execute("UPDATE scan_roots SET last_partial_scan_at=?, totals_stale=1 WHERE id=?", (timestamp(), root_id))
    conn.commit(); conn.close()
    if progress_active:
        print(file=sys.stderr)
    elapsed = int(time.monotonic() - started)
    print()
    title = "Deep scan" if scope == "full" else "Targeted refresh"
    print(f"{title} {status}: {target}")
    print(f"  Entries saved: {visited:,}    Logical file size: {human_bytes(logical_total)}    Allocated disk space: {human_bytes(allocated_total)}    Time taken: {format_duration(elapsed)}")
    if scope == "targeted":
        print(f"  Cached root: {root} ({cached_count:,} entries; whole-root total needs refresh)")
    if errors:
        print(f"  Unreadable paths: {len(errors):,} — this inventory is incomplete")
    else:
        print("  Unreadable paths: none — this inventory is complete")
    print()


def main():
    if len(sys.argv) not in {3, 4, 5, 6, 7, 8, 9, 10, 11} or sys.argv[1] not in {"init", "status", "scan", "show", "list", "set-policy", "cached-sizes", "mark-stale", "operation-log", "operation-list", "set-encryption", "remove-encryption", "list-encryption", "list-mounts", "docker-inventory", "docker-scan", "docker-search", "docker-search-path", "search", "search-direct", "search-path", "search-direct-path", "combined-search", "combined-search-path"}:
        print(__doc__, file=sys.stderr)
        return 1
    try:
        path = database_path(sys.argv[2])
        if sys.argv[1] == "init" and len(sys.argv) == 3:
            cmd_init(path)
        elif sys.argv[1] == "status" and len(sys.argv) == 3:
            cmd_status(path)
        elif sys.argv[1] == "scan" and len(sys.argv) == 5:
            cmd_scan(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "show" and len(sys.argv) in {4, 5}:
            limit = int(sys.argv[4]) if len(sys.argv) == 5 else 100
            if not 1 <= limit <= 10000:
                fail("show limit must be between 1 and 10000")
            cmd_show(path, sys.argv[3], limit)
        elif sys.argv[1] == "list" and len(sys.argv) == 3:
            cmd_list(path)
        elif sys.argv[1] == "set-policy" and len(sys.argv) == 5:
            cmd_set_policy(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "cached-sizes" and len(sys.argv) == 5:
            cmd_cached_sizes(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "mark-stale" and len(sys.argv) == 4:
            cmd_mark_stale(path, sys.argv[3])
        elif sys.argv[1] == "operation-log" and len(sys.argv) == 10:
            cmd_operation_log(path, *sys.argv[3:])
        elif sys.argv[1] == "operation-list" and len(sys.argv) in {3, 4}:
            cmd_operation_list(path, int(sys.argv[3]) if len(sys.argv) == 4 else 100)
        elif sys.argv[1] == "set-encryption" and len(sys.argv) == 5:
            cmd_set_encryption(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "remove-encryption" and len(sys.argv) == 4:
            cmd_remove_encryption(path, sys.argv[3])
        elif sys.argv[1] == "list-encryption" and len(sys.argv) == 3:
            cmd_list_encryption(path)
        elif sys.argv[1] == "list-mounts" and len(sys.argv) == 3:
            cmd_list_mounts(path)
        elif sys.argv[1] == "docker-inventory" and len(sys.argv) == 3:
            cmd_docker_inventory(path)
        elif sys.argv[1] == "docker-scan" and len(sys.argv) == 5:
            cmd_docker_scan(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "docker-session-summary" and len(sys.argv) == 4:
            cmd_docker_session_summary(path, sys.argv[3])
        elif sys.argv[1] == "docker-folder-total" and len(sys.argv) == 5:
            cmd_docker_folder_total(path, sys.argv[3], sys.argv[4])
        elif sys.argv[1] == "docker-search" and len(sys.argv) in {4, 5, 7, 8, 9, 10, 11}:
            limit = int(sys.argv[4]) if len(sys.argv) == 5 else 100
            if len(sys.argv) >= 9:
                limit = int(sys.argv[4])
                min_size = parse_size_filter(sys.argv[9]) if len(sys.argv) >= 10 else None
                max_size = parse_size_filter(sys.argv[10]) if len(sys.argv) >= 11 else None
                cmd_docker_search(path, sys.argv[3], limit, int(sys.argv[5]), None if sys.argv[6] == "-" else sys.argv[6], None if sys.argv[7] == "-" else sys.argv[7], sys.argv[8], min_size, max_size)
            elif len(sys.argv) in {7, 8}:
                limit = int(sys.argv[4])
                cmd_docker_search(path, sys.argv[3], limit, 0, None if sys.argv[5] == "-" else sys.argv[5], None if sys.argv[6] == "-" else sys.argv[6], sys.argv[7] if len(sys.argv) == 8 else "relevance")
            else:
                cmd_docker_search(path, sys.argv[3], limit)
        elif sys.argv[1] == "docker-search-path" and len(sys.argv) in {5, 7, 8, 9, 10}:
            if len(sys.argv) >= 9:
                min_size = parse_size_filter(sys.argv[8]) if len(sys.argv) >= 9 else None
                max_size = parse_size_filter(sys.argv[9]) if len(sys.argv) >= 10 else None
                cmd_docker_search_path(path, sys.argv[3], int(sys.argv[4]), None if sys.argv[5] == "-" else sys.argv[5], None if sys.argv[6] == "-" else sys.argv[6], sys.argv[7], min_size, max_size)
            elif len(sys.argv) in {7, 8}:
                cmd_docker_search_path(path, sys.argv[3], int(sys.argv[4]), None if sys.argv[5] == "-" else sys.argv[5], None if sys.argv[6] == "-" else sys.argv[6], sys.argv[7] if len(sys.argv) == 8 else "relevance")
            else:
                cmd_docker_search_path(path, sys.argv[3], int(sys.argv[4]))
        elif sys.argv[1] in {"search", "search-direct"} and len(sys.argv) in {5, 6, 7, 8, 9, 10, 11}:
            limit = int(sys.argv[5]) if len(sys.argv) >= 6 else 100
            offset = int(sys.argv[6]) if len(sys.argv) >= 7 else 0
            path_prefix = None if len(sys.argv) < 8 or sys.argv[7] == "-" else sys.argv[7]
            min_size = parse_size_filter(sys.argv[9]) if len(sys.argv) >= 10 else None
            max_size = parse_size_filter(sys.argv[10]) if len(sys.argv) >= 11 else None
            cmd_search(path, sys.argv[3], sys.argv[4], limit, offset, path_prefix, sys.argv[8] if len(sys.argv) >= 9 else "relevance", sys.argv[1] == "search-direct", min_size, max_size)
        elif sys.argv[1] in {"search-path", "search-direct-path"} and len(sys.argv) in {6, 7, 8, 9, 10}:
            min_size = parse_size_filter(sys.argv[8]) if len(sys.argv) >= 9 else None
            max_size = parse_size_filter(sys.argv[9]) if len(sys.argv) >= 10 else None
            cmd_search_path(path, sys.argv[3], sys.argv[4], int(sys.argv[5]), None if len(sys.argv) < 7 or sys.argv[6] == "-" else sys.argv[6], sys.argv[7] if len(sys.argv) >= 8 else "relevance", sys.argv[1] == "search-direct-path", min_size, max_size)
        elif sys.argv[1] == "combined-search" and len(sys.argv) in {4, 5, 6, 7, 8, 9}:
            min_size = parse_size_filter(sys.argv[7]) if len(sys.argv) >= 8 else None
            max_size = parse_size_filter(sys.argv[8]) if len(sys.argv) >= 9 else None
            cmd_combined_search(path, sys.argv[3], int(sys.argv[4]) if len(sys.argv) >= 5 else 100, int(sys.argv[5]) if len(sys.argv) >= 6 else 0, sys.argv[6] if len(sys.argv) >= 7 else "relevance", min_size, max_size)
        elif sys.argv[1] == "combined-search-path" and len(sys.argv) in {5, 6, 7, 8}:
            min_size = parse_size_filter(sys.argv[6]) if len(sys.argv) >= 7 else None
            max_size = parse_size_filter(sys.argv[7]) if len(sys.argv) >= 8 else None
            cmd_combined_search_path(path, sys.argv[3], int(sys.argv[4]), sys.argv[5] if len(sys.argv) >= 6 else "relevance", min_size, max_size)
        else:
            fail("invalid action or arguments")
    except (DatabaseError, OSError, sqlite3.Error) as exc:
        print(f"❌ Wombat Walker database: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
