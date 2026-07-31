#!/bin/bash
# Internal root worker for Wombat Walker. This is deliberately not a general interactive tool.
# The normal wombat-walker UI will invoke fixed actions through sudo when protected scan/edit
# features are implemented.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATABASE="/var/lib/wombat-walker/scans.db"

if [ "$EUID" -ne 0 ]; then
    echo "❌ This internal Walker worker must be invoked through sudo." >&2
    exit 1
fi

case "${1:-}" in
    init-db)
        [ "$#" -eq 1 ] || { echo "Usage: wombat-walker-privileged.sh init-db" >&2; exit 1; }
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" init "$DATABASE"
        ;;
    status)
        [ "$#" -eq 1 ] || { echo "Usage: wombat-walker-privileged.sh status" >&2; exit 1; }
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" status "$DATABASE"
        ;;
    scan)
        [ "$#" -eq 2 ] || { echo "Usage: wombat-walker-privileged.sh scan <directory>" >&2; exit 1; }
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" scan "$DATABASE" "$2" admin
        ;;
    show)
        [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { echo "Usage: wombat-walker-privileged.sh show <directory> [limit]" >&2; exit 1; }
        if [ "$#" -eq 3 ]; then
            exec python3 "$SCRIPT_DIR/wombat-walker-db.py" show "$DATABASE" "$2" "$3"
        fi
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" show "$DATABASE" "$2"
        ;;
    search)
        [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || { echo "Usage: wombat-walker-privileged.sh search <words> <root-or-dash> [limit] [offset] [order]" >&2; exit 1; }
        if [ "$#" -eq 6 ]; then
            exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$DATABASE" "$2" "$3" "$4" "$5" - "$6"
        fi
        if [ "$#" -eq 5 ]; then
            exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$DATABASE" "$2" "$3" "$4" "$5"
        fi
        if [ "$#" -eq 4 ]; then
            exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$DATABASE" "$2" "$3" "$4"
        fi
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$DATABASE" "$2" "$3"
        ;;
    search-path)
        [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || { echo "Usage: wombat-walker-privileged.sh search-path <words> <root-or-dash> <number> [order]" >&2; exit 1; }
        if [ "$#" -eq 5 ]; then
            exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search-path "$DATABASE" "$2" "$3" "$4" - "$5"
        fi
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" search-path "$DATABASE" "$2" "$3" "$4"
        ;;
    set-policy)
        [ "$#" -eq 3 ] || { echo "Usage: wombat-walker-privileged.sh set-policy <root> <active|archive|manual>" >&2; exit 1; }
        exec python3 "$SCRIPT_DIR/wombat-walker-db.py" set-policy "$DATABASE" "$2" "$3"
        ;;
    list-directory)
        [ "$#" -eq 2 ] || { echo "Usage: wombat-walker-privileged.sh list-directory <directory>" >&2; exit 1; }
        exec python3 "$SCRIPT_DIR/wombat-walker-privileged-list.py" "$2"
        ;;
    view-file)
        [ "$#" -eq 2 ] || { echo "Usage: wombat-walker-privileged.sh view-file <regular-file>" >&2; exit 1; }
        [ -f "$2" ] && [ ! -L "$2" ] || { echo "❌ Protected viewing is limited to regular non-symlink files." >&2; exit 1; }
        [ -x /usr/bin/less ] || { echo "❌ /usr/bin/less is required for safe protected viewing." >&2; exit 1; }
        exec env -i PATH=/usr/bin:/bin HOME=/root TERM="${TERM:-dumb}" LESSSECURE=1 /usr/bin/less -- "$2"
        ;;
    *)
        echo "Usage: wombat-walker-privileged.sh <init-db|status|scan|show|search|search-path|set-policy|list-directory|view-file>" >&2
        exit 1
        ;;
esac
