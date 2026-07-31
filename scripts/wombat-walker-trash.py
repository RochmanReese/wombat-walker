#!/usr/bin/env python3
"""Portable, user-owned Trash storage for Wombat Walker.

Usage:
  wombat-walker-trash.py move <trash-root> <source-path>
  wombat-walker-trash.py list <trash-root>
  wombat-walker-trash.py restore <trash-root> <entry-id>
  wombat-walker-trash.py purge <trash-root> <entry-id>

Records are NUL-separated so names containing spaces or newlines remain safe.  This helper never
uses the desktop Trash, a shell command, or sudo.
"""
import errno
import json
import os
import shutil
import stat
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


def fail(message):
    print(f"❌ Wombat Trash: {message}", file=sys.stderr)
    raise SystemExit(1)


def private_directory(path: Path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        path.mkdir(mode=0o700, parents=True)
        info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(f"not a real directory: {path}")
    if info.st_uid != os.geteuid():
        fail(f"not owned by the logged-in user: {path}")
    os.chmod(path, 0o700)


def layout(raw_root):
    root = Path(raw_root)
    if not root.is_absolute():
        fail("Trash root must be absolute")
    private_directory(root.parent)
    private_directory(root)
    items = root / "items"
    metadata = root / "metadata"
    private_directory(items)
    private_directory(metadata)
    return root, items, metadata


def entry_id(raw):
    if not raw or any(char not in "0123456789abcdef-" for char in raw) or len(raw) != 36:
        fail("invalid Trash entry id")
    return raw


def emit(*values):
    output = sys.stdout.buffer
    for value in values:
        output.write(str(value).encode("utf-8", "surrogateescape") + b"\0")


def measure(path):
    info = os.lstat(path)
    if stat.S_ISREG(info.st_mode):
        return info.st_size, getattr(info, "st_blocks", 0) * 512, "file"
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail("only regular files and real folders can enter Wombat Trash")
    logical = allocated = 0
    for base, dirs, files in os.walk(path, topdown=True, followlinks=False):
        for name in dirs + files:
            child = os.path.join(base, name)
            try:
                child_info = os.lstat(child)
            except OSError:
                continue
            logical += child_info.st_size if stat.S_ISREG(child_info.st_mode) else 0
            allocated += getattr(child_info, "st_blocks", 0) * 512
    allocated += getattr(info, "st_blocks", 0) * 512
    return logical, allocated, "directory"


def move_across_filesystems(source, destination, kind):
    try:
        os.rename(source, destination)
        return
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise
    if kind == "directory":
        shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)
        shutil.rmtree(source)
    else:
        shutil.copy2(source, destination, follow_symlinks=False)
        os.unlink(source)


def cmd_move(root, source):
    _, items, metadata_dir = layout(root)
    source = os.path.abspath(source)
    try:
        source_info = os.lstat(source)
    except OSError as exc:
        fail(f"cannot inspect source: {exc}")
    if stat.S_ISLNK(source_info.st_mode):
        fail("symbolic links cannot enter Wombat Trash")
    logical, allocated, kind = measure(source)
    identifier = str(uuid.uuid4())
    destination = items / identifier
    try:
        move_across_filesystems(source, str(destination), kind)
    except OSError as exc:
        if destination.exists():
            if destination.is_dir():
                shutil.rmtree(destination)
            else:
                destination.unlink()
        fail(f"could not move item into Wombat Trash: {exc}")
    record = {
        "id": identifier,
        "original_path": source,
        "entry_type": kind,
        "logical_size_bytes": logical,
        "allocated_size_bytes": allocated,
        "trashed_at": datetime.now(timezone.utc).isoformat(),
    }
    metadata_path = metadata_dir / f"{identifier}.json"
    temporary = metadata_path.with_suffix(".tmp")
    with open(temporary, "x", encoding="utf-8") as handle:
        json.dump(record, handle, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, metadata_path)
    emit(identifier, source, kind, logical, allocated, record["trashed_at"])


def record_for(metadata_dir, identifier):
    identifier = entry_id(identifier)
    path = metadata_dir / f"{identifier}.json"
    try:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            fail("Trash metadata is not a regular file")
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read Trash metadata: {exc}")
    if record.get("id") != identifier or not os.path.isabs(record.get("original_path", "")):
        fail("invalid Trash metadata")
    return path, record


def cmd_list(root):
    _, items, metadata_dir = layout(root)
    records = []
    for metadata_path in metadata_dir.glob("*.json"):
        try:
            _, record = record_for(metadata_dir, metadata_path.stem)
        except SystemExit:
            continue
        item = items / record["id"]
        try:
            info = os.lstat(item)
        except OSError:
            continue
        if stat.S_ISLNK(info.st_mode):
            continue
        records.append(record)
    for record in sorted(records, key=lambda item: item["trashed_at"], reverse=True):
        emit(record["id"], record["original_path"], record["entry_type"], record["logical_size_bytes"], record["allocated_size_bytes"], record["trashed_at"])


def cmd_restore(root, identifier):
    _, items, metadata_dir = layout(root)
    metadata_path, record = record_for(metadata_dir, identifier)
    item = items / record["id"]
    original = record["original_path"]
    if not item.exists() or os.path.islink(item):
        fail("Trash item is missing or unsafe")
    parent = os.path.dirname(original)
    if not os.path.isdir(parent) or not os.access(parent, os.W_OK | os.X_OK):
        fail("original folder is missing or not writable; choose a future restore destination instead")
    if os.path.lexists(original):
        fail("original path already exists; Wombat Trash will not overwrite it")
    move_across_filesystems(str(item), original, record["entry_type"])
    metadata_path.unlink()
    emit(record["id"], original, record["entry_type"], record["logical_size_bytes"], record["allocated_size_bytes"])


def cmd_purge(root, identifier):
    _, items, metadata_dir = layout(root)
    metadata_path, record = record_for(metadata_dir, identifier)
    item = items / record["id"]
    try:
        info = os.lstat(item)
    except OSError as exc:
        fail(f"Trash item is missing: {exc}")
    if stat.S_ISLNK(info.st_mode):
        fail("symbolic links cannot be purged through Wombat Trash")
    if stat.S_ISDIR(info.st_mode):
        shutil.rmtree(item)
    elif stat.S_ISREG(info.st_mode):
        item.unlink()
    else:
        fail("Trash item is not a regular file or folder")
    metadata_path.unlink()
    emit(record["id"], record["original_path"], record["entry_type"], record["logical_size_bytes"], record["allocated_size_bytes"])


def main():
    if len(sys.argv) not in {3, 4} or sys.argv[1] not in {"move", "list", "restore", "purge"}:
        print(__doc__, file=sys.stderr)
        return 1
    action, root = sys.argv[1], sys.argv[2]
    if action == "list" and len(sys.argv) == 3:
        cmd_list(root)
    elif action == "move" and len(sys.argv) == 4:
        cmd_move(root, sys.argv[3])
    elif action == "restore" and len(sys.argv) == 4:
        cmd_restore(root, sys.argv[3])
    elif action == "purge" and len(sys.argv) == 4:
        cmd_purge(root, sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
