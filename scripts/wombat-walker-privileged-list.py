#!/usr/bin/env python3
"""Emit one protected directory listing as NUL-delimited metadata for Walker's normal UI."""
import os
import stat
import sys


def main():
    if len(sys.argv) != 2:
        print("Usage: wombat-walker-privileged-list.py <directory>", file=sys.stderr)
        return 2
    directory = os.path.realpath(sys.argv[1])
    try:
        entries = list(os.scandir(directory))
    except OSError as exc:
        print(f"❌ Cannot inspect protected folder {directory}: {exc}", file=sys.stderr)
        return 1
    records = []
    for entry in entries:
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(info.st_mode):
            kind = "dir"
        elif stat.S_ISLNK(info.st_mode):
            kind = "sym"
        elif stat.S_ISREG(info.st_mode):
            kind = "file"
        else:
            kind = "other"
        records.append((entry.name, kind, entry.path, str(info.st_size), str(info.st_mtime_ns)))
    records.sort(key=lambda record: (record[1] != "dir", record[0].casefold()))
    output = sys.stdout.buffer
    for record in records:
        for value in record:
            output.write(value.encode("utf-8", "surrogateescape") + b"\0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
