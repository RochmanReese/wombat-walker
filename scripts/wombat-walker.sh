#!/bin/bash
# Wombat Walker — cautious filesystem explorer.
#
# Run as the logged-in user. Protected deep scans and edits request sudo only when that explicit
# action is implemented and selected.
#
# Walker only changes a file when the user explicitly enters its action menu. It can edit regular
# files and move ordinary user-owned files or folders to Trash; it does not use sudo for deletion.

set -e

SHOW_FILE_SIZES="on"
ITEMS_PER_PAGE=30
ITEMS_PER_PAGE_SET=false
SORT_ORDER="alphabetical"
SORT_ORDER_SET=false
SHOW_HIDDEN="off"
DOCKER_SORT_ORDER="alphabetical"
DOCKER_FILE_SORT_ORDER="alphabetical"
DEFAULT_FILE_SORT_ORDER="alphabetical"
DEEP_SCAN=""
USE_SUDO_SCAN="off"
PRIVILEGED_MODE="${WOMBAT_WALKER_PRIVILEGED_MODE:-on}"
SHOW_SCAN=""
SHOW_LIMIT=100
SEARCH_WORDS=""
SEARCH_ROOT=""
SEARCH_LIMIT=100
SET_POLICY=""
PRIVILEGED_BROWSE=""
FILE_ACTION=""
DOCKER_LAUNCH="off"
DISK_HEALTH_LAUNCH="off"
PICK_FOLDER="off"
START_PATH="/"
START_PATH_SET=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALKER_DATABASE="${WOMBAT_WALKER_DB:-$HOME/.local/state/wombat-walker/scans.db}"
WALKER_TRASH_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/wombat-walker/trash"
WALKER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wombat-walker"
WALKER_PREFERENCES="$WALKER_CONFIG_DIR/preferences.conf"
PREFERRED_EDITOR="default"

usage() {
    cat <<'EOF'
Usage: wombat-walker.sh [start-path] [options]

Server filesystem explorer. Protected actions request sudo only for the specific action that needs it.

Options:
  --filesize on|off
  --items-per-page 1-200
  --sort alphabetical|largest|smallest|updated
  --hidden on|off
  --deep-scan current|filesystem  Save a complete accessible inventory in Walker's scan cache
  --sudo                         Use the narrow sudo worker with --deep-scan, --show-scan, --search, or --set-policy
  --show-scan current|filesystem  Display the saved inventory for this folder/filesystem
  --show-limit 1-10000            Entries to display with --show-scan (default: 100)
  --list-scans                    List every saved normal-user scan root
  --search <words>                Search saved path/name metadata
  --root <scan-root>              Limit --search to one saved scan root
  --search-limit 1-10000          Results to display with --search (default: 100)
  --set-policy active|archive|manual --root <scan-root>  Set a saved root's refresh policy
  --docker                       Open the Docker workspace directly
  --diskcheck                    Open the read-only NVMe disk health checker directly
  --pick-folder                  Picker mode: return a chosen folder path to the calling app
  --home                         Start in the logged-in user's home folder
  --here                         Start in the directory where Walker was launched
  --privileged-browse <path>     Internal: run one protected-folder browser session
  --file-action <path>           Internal: open the action menu for one regular file
  --help
EOF
}

walker_help_screen() {
    echo
    echo "====================== Wombat Walker help ======================"
    usage
    echo
    echo "Browser keys: numbered item opens it; [.] selects this folder in picker mode; [u] goes up;"
    echo "[d] returns to the previous folder; [n]/[p] change page; [o] changes order."
    echo "[m] enters a path; [s] refreshes and searches the current folder or saved scans; [x] opens utilities and this help; [q] quits."
    echo "Use --docker to open Docker directly: browse live container files, see where Docker stores"
    echo "its data, and save fast searchable file/path inventories without changing a container."
    echo "Use --diskcheck to open the physical-NVMe health checker directly."
    echo "In Docker, [a] scans all running containers after confirmation; stopped containers are skipped."
    echo
    echo "Regular files offer safe view, editor choices, and recoverable Move to Trash."
    echo "Protected paths request sudo only for safe view/edit or protected browsing; deletion never uses sudo."
    echo
    echo "Full offline reference: $SCRIPT_DIR/../help.md"
    echo "================================================================="
}

while [ $# -gt 0 ]; do
    case "$1" in
        --filesize) SHOW_FILE_SIZES="$2"; shift 2 ;;
        --items-per-page) ITEMS_PER_PAGE="$2"; ITEMS_PER_PAGE_SET=true; shift 2 ;;
        --sort) SORT_ORDER="$2"; SORT_ORDER_SET=true; shift 2 ;;
        --hidden) SHOW_HIDDEN="$2"; shift 2 ;;
        --deep-scan) DEEP_SCAN="$2"; shift 2 ;;
        --sudo) USE_SUDO_SCAN="on"; shift ;;
        --show-scan) SHOW_SCAN="$2"; shift 2 ;;
        --show-limit) SHOW_LIMIT="$2"; shift 2 ;;
        --list-scans) LIST_SCANS="on"; shift ;;
        --search) SEARCH_WORDS="$2"; shift 2 ;;
        --root) SEARCH_ROOT="$2"; shift 2 ;;
        --search-limit) SEARCH_LIMIT="$2"; shift 2 ;;
        --set-policy) SET_POLICY="$2"; shift 2 ;;
        --docker) DOCKER_LAUNCH="on"; shift ;;
        --diskcheck) DISK_HEALTH_LAUNCH="on"; shift ;;
        --pick-folder) PICK_FOLDER="on"; shift ;;
        --privileged-browse) PRIVILEGED_BROWSE="$2"; shift 2 ;;
        --file-action) FILE_ACTION="$2"; shift 2 ;;
        --home) START_PATH="${HOME:-/}"; START_PATH_SET=true; shift ;;
        --here) START_PATH="$PWD"; START_PATH_SET=true; shift ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "❌ Unknown option: $1"; usage; exit 1 ;;
        *)
            if ! $START_PATH_SET; then
                START_PATH="$1"
                START_PATH_SET=true
                shift
            else
                echo "❌ Only one start path may be supplied."
                usage
                exit 1
            fi
            ;;
    esac
done

if [ "$SHOW_FILE_SIZES" != "on" ] && [ "$SHOW_FILE_SIZES" != "off" ]; then
    echo "❌ --filesize must be 'on' or 'off'."; exit 1
fi
if ! [[ "$ITEMS_PER_PAGE" =~ ^[0-9]+$ ]] || [ "$ITEMS_PER_PAGE" -lt 1 ] || [ "$ITEMS_PER_PAGE" -gt 200 ]; then
    echo "❌ --items-per-page must be a whole number from 1 to 200."; exit 1
fi
if [ "$SORT_ORDER" != "alphabetical" ] && [ "$SORT_ORDER" != "largest" ] && [ "$SORT_ORDER" != "smallest" ] && [ "$SORT_ORDER" != "updated" ]; then
    echo "❌ --sort must be alphabetical, largest, smallest, or updated."; exit 1
fi
if [ "$SHOW_HIDDEN" != "on" ] && [ "$SHOW_HIDDEN" != "off" ]; then
    echo "❌ --hidden must be 'on' or 'off'."; exit 1
fi
if [ -n "$DEEP_SCAN" ] && [ "$DEEP_SCAN" != "current" ] && [ "$DEEP_SCAN" != "filesystem" ]; then
    echo "❌ --deep-scan must be 'current' or 'filesystem'."; exit 1
fi
if [ -n "$SHOW_SCAN" ] && [ "$SHOW_SCAN" != "current" ] && [ "$SHOW_SCAN" != "filesystem" ]; then
    echo "❌ --show-scan must be 'current' or 'filesystem'."; exit 1
fi
if ! [[ "$SHOW_LIMIT" =~ ^[0-9]+$ ]] || [ "$SHOW_LIMIT" -lt 1 ] || [ "$SHOW_LIMIT" -gt 10000 ]; then
    echo "❌ --show-limit must be a whole number from 1 to 10000."; exit 1
fi
if ! [[ "$SEARCH_LIMIT" =~ ^[0-9]+$ ]] || [ "$SEARCH_LIMIT" -lt 1 ] || [ "$SEARCH_LIMIT" -gt 10000 ]; then
    echo "❌ --search-limit must be a whole number from 1 to 10000."; exit 1
fi
if [ -n "$SEARCH_ROOT" ] && [ -z "$SEARCH_WORDS" ] && [ -z "$SET_POLICY" ]; then
    echo "❌ --root is only valid with --search or --set-policy."; exit 1
fi
if [ -n "$SET_POLICY" ] && [ "$SET_POLICY" != "active" ] && [ "$SET_POLICY" != "archive" ] && [ "$SET_POLICY" != "manual" ]; then
    echo "❌ --set-policy must be active, archive, or manual."; exit 1
fi
if [ -n "$SET_POLICY" ] && [ -z "$SEARCH_ROOT" ]; then
    echo "❌ --set-policy requires --root <saved-scan-root>."; exit 1
fi
ACTION_COUNT=0
[ -n "$DEEP_SCAN" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ -n "$SHOW_SCAN" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ -n "$SEARCH_WORDS" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ -n "$SET_POLICY" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ "$DOCKER_LAUNCH" = "on" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ "$DISK_HEALTH_LAUNCH" = "on" ] && ACTION_COUNT=$((ACTION_COUNT + 1))
[ "$ACTION_COUNT" -le 1 ] || { echo "❌ Use only one direct action at a time."; exit 1; }
if [ "${LIST_SCANS:-off}" = "on" ] && { [ -n "$DEEP_SCAN" ] || [ -n "$SHOW_SCAN" ] || [ -n "$SEARCH_WORDS" ] || [ -n "$SET_POLICY" ]; }; then
    echo "❌ --list-scans cannot be combined with another cache action."; exit 1
fi
if [ "$USE_SUDO_SCAN" = "on" ] && [ -z "$DEEP_SCAN" ] && [ -z "$SHOW_SCAN" ] && [ -z "$SEARCH_WORDS" ] && [ -z "$SET_POLICY" ]; then
    echo "❌ --sudo is only valid with --deep-scan, --show-scan, --search, or --set-policy."; exit 1
fi
if [ "$USE_SUDO_SCAN" = "on" ] && [ "$PRIVILEGED_MODE" != "on" ]; then
    echo "❌ This user-only Walker install does not run protected actions. Install with --system for that feature."
    exit 1
fi
if [ "$SHOW_FILE_SIZES" = "off" ] && { [ "$SORT_ORDER" = "largest" ] || [ "$SORT_ORDER" = "smallest" ]; }; then
    echo "❌ --sort $SORT_ORDER requires --filesize on."; exit 1
fi
if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" init "$WALKER_DATABASE"; then
    echo "❌ Wombat Walker could not initialise its private user scan database."
    exit 1
fi
if [ ! -e "$START_PATH" ]; then
    echo "❌ Start path does not exist: $START_PATH"; exit 1
fi
[ -d "$START_PATH" ] || START_PATH="$(dirname "$START_PATH")"

if [ "${LIST_SCANS:-off}" = "on" ]; then
    exec python3 "$SCRIPT_DIR/wombat-walker-db.py" list "$WALKER_DATABASE"
fi

if [ -n "$SET_POLICY" ]; then
    SEARCH_ROOT="$(realpath -m "$SEARCH_ROOT")"
    if [ "$USE_SUDO_SCAN" = "on" ]; then
        exec sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" set-policy "$SEARCH_ROOT" "$SET_POLICY"
    fi
    exec python3 "$SCRIPT_DIR/wombat-walker-db.py" set-policy "$WALKER_DATABASE" "$SEARCH_ROOT" "$SET_POLICY"
fi

if [ -n "$DEEP_SCAN" ]; then
    if [ "$DEEP_SCAN" = "filesystem" ]; then
        SCAN_ROOT="$(df --output=target "$START_PATH" 2>/dev/null | awk 'NR == 2 { sub(/^ +/, ""); print; exit }')"
        [ -n "$SCAN_ROOT" ] || { echo "❌ Could not find the filesystem containing: $START_PATH"; exit 1; }
    else
        SCAN_ROOT="$(realpath "$START_PATH")"
    fi
    echo "Starting deep scan of: $SCAN_ROOT"
    if [ "$USE_SUDO_SCAN" = "on" ]; then
        exec sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" scan "$SCAN_ROOT"
    fi
    exec python3 "$SCRIPT_DIR/wombat-walker-db.py" scan "$WALKER_DATABASE" "$SCAN_ROOT" little
fi

if [ -n "$SHOW_SCAN" ]; then
    if [ "$SHOW_SCAN" = "filesystem" ]; then
        SCAN_ROOT="$(df --output=target "$START_PATH" 2>/dev/null | awk 'NR == 2 { sub(/^ +/, ""); print; exit }')"
        [ -n "$SCAN_ROOT" ] || { echo "❌ Could not find the filesystem containing: $START_PATH"; exit 1; }
    else
        SCAN_ROOT="$(realpath "$START_PATH")"
    fi
    if [ "$USE_SUDO_SCAN" = "on" ]; then
        exec sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" show "$SCAN_ROOT" "$SHOW_LIMIT"
    fi
    exec python3 "$SCRIPT_DIR/wombat-walker-db.py" show "$WALKER_DATABASE" "$SCAN_ROOT" "$SHOW_LIMIT"
fi

if [ -n "$SEARCH_WORDS" ]; then
    if [ -n "$SEARCH_ROOT" ]; then
        SEARCH_ROOT="$(realpath -m "$SEARCH_ROOT")"
    else
        SEARCH_ROOT="-"
    fi
    if [ ! -t 0 ]; then
        if [ "$USE_SUDO_SCAN" = "on" ]; then
            sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" search "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_LIMIT"
        else
            python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$WALKER_DATABASE" "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_LIMIT"
        fi
        exit 0
    fi
    SEARCH_OFFSET=0
    SEARCH_ORDER="relevance"
    while true; do
        if [ "$USE_SUDO_SCAN" = "on" ]; then
            sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" search "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_LIMIT" "$SEARCH_OFFSET" "$SEARCH_ORDER"
        else
            python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$WALKER_DATABASE" "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_LIMIT" "$SEARCH_OFFSET" - "$SEARCH_ORDER"
        fi
        echo
        echo "  [n] Next page    [p] Previous page    [o] Change result order    [q] Return"
        read -r -e -p "Open displayed result number, or choose n/p/o/q: " SEARCH_RESULT_NUMBER
        case "$SEARCH_RESULT_NUMBER" in
            q|Q|"") exit 0 ;;
            n|N) SEARCH_OFFSET=$((SEARCH_OFFSET + SEARCH_LIMIT)); continue ;;
            p|P)
                if [ "$SEARCH_OFFSET" -ge "$SEARCH_LIMIT" ]; then
                    SEARCH_OFFSET=$((SEARCH_OFFSET - SEARCH_LIMIT))
                else
                    echo "❌ This is the first search-results page."
                fi
                continue
                ;;
            o|O)
                echo "  [1] Search relevance  [2] Largest first  [3] Smallest first  [4] Most recently updated"
                read -r -e -p "> " SEARCH_ORDER_CHOICE
                case "$SEARCH_ORDER_CHOICE" in
                    1) SEARCH_ORDER="relevance" ;; 2) SEARCH_ORDER="largest" ;;
                    3) SEARCH_ORDER="smallest" ;; 4) SEARCH_ORDER="updated" ;;
                    *) echo "❌ Enter 1, 2, 3, or 4."; continue ;;
                esac
                SEARCH_OFFSET=0
                continue
                ;;
            *[!0-9]*|0) echo "❌ Enter a displayed result number, n, p, o, or q."; continue ;;
        esac
        if [ "$SEARCH_RESULT_NUMBER" -le "$SEARCH_OFFSET" ] || [ "$SEARCH_RESULT_NUMBER" -gt $((SEARCH_OFFSET + SEARCH_LIMIT)) ]; then
            echo "❌ Enter a result number shown on this page."
            continue
        fi
        break
    done
    if [ "$USE_SUDO_SCAN" = "on" ]; then
        SEARCH_RESULT_PATH="$(sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" search-path "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_RESULT_NUMBER" "$SEARCH_ORDER" 2>/dev/null || true)"
    else
        SEARCH_RESULT_PATH="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" search-path "$WALKER_DATABASE" "$SEARCH_WORDS" "$SEARCH_ROOT" "$SEARCH_RESULT_NUMBER" - "$SEARCH_ORDER" 2>/dev/null || true)"
    fi
    if [ -z "$SEARCH_RESULT_PATH" ]; then
        echo "❌ That result number is outside the displayed search results."
        exit 1
    fi
    if [ ! -e "$SEARCH_RESULT_PATH" ]; then
        echo "❌ Cached result is no longer present: $SEARCH_RESULT_PATH"
        echo "  Refresh the relevant folder before relying on this result."
        exit 1
    fi
    if [ -d "$SEARCH_RESULT_PATH" ] && [ -r "$SEARCH_RESULT_PATH" ] && [ -x "$SEARCH_RESULT_PATH" ]; then
        exec "$0" "$SEARCH_RESULT_PATH" --filesize "$SHOW_FILE_SIZES" --items-per-page "$ITEMS_PER_PAGE" --sort "$SORT_ORDER" --hidden "$SHOW_HIDDEN"
    fi
    if [ -d "$SEARCH_RESULT_PATH" ]; then
        echo "Protected folder: $SEARCH_RESULT_PATH"
        echo "You do not have permission to inspect its contents."
        read -r -e -p "Request temporary sudo access to browse it? [y/N] " REQUEST_ELEVATION
        case "$REQUEST_ELEVATION" in
            y|Y|yes|YES) exec "$0" --privileged-browse "$SEARCH_RESULT_PATH" ;;
            *) echo "Returned without requesting elevated access." ;;
        esac
    else
        if [ -f "$SEARCH_RESULT_PATH" ] && [ ! -L "$SEARCH_RESULT_PATH" ]; then
            exec "$0" --file-action "$SEARCH_RESULT_PATH"
        elif [ -L "$SEARCH_RESULT_PATH" ]; then
            echo "❌ Cannot edit this selection: it is a symbolic link."
            echo "  Resolve or manage the link outside Wombat Walker, then select the actual regular file."
        else
            echo "❌ This selection is not an ordinary regular file. Manage it outside Wombat Walker."
        fi
    fi
    exit 0
fi

human_bytes() {
    local bytes="$1"
    awk -v bytes="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units, " ")
        unit = 1
        while (bytes >= 1000 && unit < 6) { bytes /= 1000; unit++ }
        if (unit == 1) printf "%.0f%s", bytes, units[unit]
        else printf "%.2f%s", bytes, units[unit]
    }'
}

browse_protected_folder() {
    local current choice target index item_name display_name size_bytes modified_display i entry_kind
    local -a fields entries
    current="$1"
    if [ "$PRIVILEGED_MODE" != "on" ]; then
        echo "❌ Protected browsing is unavailable in this user-only Walker install."
        return 0
    fi
    while true; do
        fields=()
        mapfile -d '' -t fields < <(sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" list-directory "$current")
        if [ "${#fields[@]}" -eq 0 ] && [ ! -d "$current" ]; then
            echo "❌ Protected folder is no longer available: $current"
            return 1
        fi
        entries=()
        echo
        echo "=================================================================================================="
        echo "Wombat Walker — protected read-only browser"
        echo "Current folder: $current"
        echo "Each listing uses a short-lived sudo worker; this Walker session remains unprivileged."
        echo "=================================================================================================="
        echo "  [u] Go up one folder    [m] Type a path    [q] Return to normal Walker"
        echo
        printf "  %-5s%-10s%-38s %12s  %-16s\n" "No." "Type" "Name" "Size" "Last updated"
        index=1
        for ((i=0; i<${#fields[@]}; i+=5)); do
            item_name="${fields[$i]}"; target="${fields[$((i + 2))]}"; size_bytes="${fields[$((i + 3))]}"
            entry_kind="${fields[$((i + 1))]}"
            display_name="$item_name"
            [ "${#display_name}" -le 38 ] || display_name="${display_name:0:35}..."
            modified_display="$(date -d "@$((${fields[$((i + 4))]} / 1000000000))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
            printf "  %-5s%-10s%-38s %12s  %-16s\n" "[$index]" "$entry_kind" "$display_name" "$(human_bytes "$size_bytes")" "$modified_display"
            entries+=("$target")
            index=$((index + 1))
        done
        echo
        read -r -e -p "> " choice
        case "$choice" in
            q|Q) return 0 ;;
            u|U) [ "$current" = "/" ] || current="$(dirname "$current")" ;;
            m|M)
                read -r -e -p "Protected path: " target
                [ -d "$target" ] && current="$target" || echo "❌ That protected path is not a directory."
                ;;
            *)
                if [[ "$choice" == /* || "$choice" == "~" || "$choice" == "~/"* ]]; then
                    manual_path="$choice"
                    [ "$manual_path" = "~" ] && manual_path="$HOME"
                    [[ "$manual_path" == "~/"* ]] && manual_path="$HOME/${manual_path#\~/}"
                    if [ -d "$manual_path" ]; then
                        back_history+=("$current"); current="$(realpath "$manual_path")"; page=0
                    elif [ -f "$manual_path" ] && [ ! -L "$manual_path" ]; then
                        file_action_menu "$(realpath "$manual_path")"
                    else
                        notice="❌ That path does not exist or is not an ordinary folder/file: $choice"
                    fi
                elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
                    target="${entries[$((choice - 1))]}"
                    if [ -d "$target" ]; then
                        current="$target"
                    else
                        echo "Selected protected file: $target"
                        echo "  Safe privileged viewing/editing is the next separate action."
                    fi
                else
                    echo "❌ Enter a listed number, u, m, or q."
                fi
                ;;
        esac
    done
}

editor_path() {
    case "$1" in
        default) [ -x /usr/bin/editor ] && echo /usr/bin/editor ;;
        nano) [ -x /usr/bin/nano ] && echo /usr/bin/nano ;;
        vim) [ -x /usr/bin/vim ] && echo /usr/bin/vim ;;
    esac
}

editor_label() {
    case "$1" in
        default) echo "system terminal editor" ;;
        nano) echo "Nano" ;;
        vim) echo "Vim" ;;
    esac
}

load_preferences() {
    local saved_editor saved_docker_order saved_file_order saved_items_per_page
    [ -r "$WALKER_PREFERENCES" ] || return 0
    saved_editor="$(sed -n 's/^PREFERRED_EDITOR=//p' "$WALKER_PREFERENCES" | head -n 1)"
    case "$saved_editor" in
        default|nano|vim) PREFERRED_EDITOR="$saved_editor" ;;
    esac
    saved_docker_order="$(sed -n 's/^DOCKER_SORT_ORDER=//p' "$WALKER_PREFERENCES" | head -n 1)"
    case "$saved_docker_order" in
        alphabetical|status|writable|virtual|persistent) DOCKER_SORT_ORDER="$saved_docker_order" ;;
    esac
    saved_file_order="$(sed -n 's/^DEFAULT_FILE_SORT_ORDER=//p' "$WALKER_PREFERENCES" | head -n 1)"
    case "$saved_file_order" in
        alphabetical|largest|smallest|updated)
            DEFAULT_FILE_SORT_ORDER="$saved_file_order"
            [ "$SORT_ORDER_SET" = true ] || SORT_ORDER="$saved_file_order"
            DOCKER_FILE_SORT_ORDER="$saved_file_order"
            ;;
    esac
    saved_items_per_page="$(sed -n 's/^ITEMS_PER_PAGE=//p' "$WALKER_PREFERENCES" | head -n 1)"
    if [ "$ITEMS_PER_PAGE_SET" = false ] && [[ "$saved_items_per_page" =~ ^[0-9]+$ ]] && [ "$saved_items_per_page" -ge 1 ] && [ "$saved_items_per_page" -le 200 ]; then
        ITEMS_PER_PAGE="$saved_items_per_page"
    fi
}

save_preference() {
    local preference_key="$1" preference_value="$2" temporary_preferences
    mkdir -p "$WALKER_CONFIG_DIR" || { echo "❌ Could not save Walker's settings."; return 1; }
    chmod 700 "$WALKER_CONFIG_DIR" 2>/dev/null || true
    temporary_preferences="$(mktemp "$WALKER_CONFIG_DIR/preferences.XXXXXX")" || {
        echo "❌ Could not create Walker's settings file."
        return 1
    }
    if [ -r "$WALKER_PREFERENCES" ]; then
        sed "/^${preference_key}=/d" "$WALKER_PREFERENCES" > "$temporary_preferences"
    fi
    printf '%s=%s\n' "$preference_key" "$preference_value" >> "$temporary_preferences"
    chmod 600 "$temporary_preferences" 2>/dev/null || true
    mv "$temporary_preferences" "$WALKER_PREFERENCES" || {
        echo "❌ Could not save Walker's settings."
        return 1
    }
}

save_preferred_editor() {
    save_preference "PREFERRED_EDITOR" "$PREFERRED_EDITOR"
}

save_default_file_order() {
    DEFAULT_FILE_SORT_ORDER="$1"
    SORT_ORDER="$1"
    DOCKER_FILE_SORT_ORDER="$1"
    save_preference "DEFAULT_FILE_SORT_ORDER" "$DEFAULT_FILE_SORT_ORDER"
}

choose_preferred_editor() {
    local editor_choice
    echo
    echo "Choose preferred editor (currently: $(editor_label "$PREFERRED_EDITOR"))"
    echo "  [1] System terminal editor"
    echo "  [2] Nano"
    echo "  [3] Vim"
    echo "  [q] Keep current setting"
    read -r -e -p "> " editor_choice
    case "$editor_choice" in
        1) PREFERRED_EDITOR="default" ;;
        2) PREFERRED_EDITOR="nano" ;;
        3) PREFERRED_EDITOR="vim" ;;
        q|Q|"") return 0 ;;
        *) echo "❌ Enter 1, 2, 3, or q."; return 1 ;;
    esac
    if save_preferred_editor; then
        echo "Preferred editor saved: $(editor_label "$PREFERRED_EDITOR")"
        echo "Settings file: $WALKER_PREFERENCES"
    fi
}

choose_one_off_editor() {
    local editor_choice
    ONE_OFF_EDITOR=""
    echo
    echo "Choose editor for this file only"
    echo "  [1] System terminal editor"
    echo "  [2] Nano"
    echo "  [3] Vim"
    echo "  [q] Return without editing"
    read -r -e -p "> " editor_choice
    case "$editor_choice" in
        1) ONE_OFF_EDITOR="default" ;;
        2) ONE_OFF_EDITOR="nano" ;;
        3) ONE_OFF_EDITOR="vim" ;;
        q|Q|"") return 0 ;;
        *) echo "❌ Enter 1, 2, 3, or q."; return 1 ;;
    esac
}

docker_help_screen() {
    echo
    echo "================== How Docker storage works =================="
    echo "A container is an isolated running application. Its ordinary internal files"
    echo "are disposable: recreating the container can replace them."
    echo
    echo "Bind mount: a normal server folder shared with the container. It is best"
    echo "managed as a host folder because you can browse, back up, and Trash it normally."
    echo
    echo "Named volume: persistent storage managed by Docker, commonly used for"
    echo "databases and application data. It survives container replacement."
    echo
    echo "Docker Desktop also stores its Linux VM in a sparse virtual disk. Its"
    echo "virtual capacity can be much larger than the host space physically used."
    echo
    echo "This Docker workspace is read-only for now. It is safe for discovery:"
    echo "browse a running container, inspect its mounts, and find where its data lives."
    echo "Copy-out and carefully guarded data cleanup will be added separately."
    echo "==============================================================="
}

docker_desktop_disk_summary() {
    local disk_path logical_bytes allocated_blocks allocated_bytes
    for disk_path in \
        "$HOME/.docker/desktop/vms/0/data/Docker.raw" \
        "$HOME/.docker/desktop/vms/0/data/Docker.qcow2"; do
        [ -f "$disk_path" ] || continue
        read -r logical_bytes allocated_blocks < <(stat -c '%s %b' -- "$disk_path" 2>/dev/null || true)
        [[ "$logical_bytes" =~ ^[0-9]+$ ]] || continue
        [[ "$allocated_blocks" =~ ^[0-9]+$ ]] || allocated_blocks=0
        allocated_bytes=$((allocated_blocks * 512))
        printf "Docker Desktop virtual disk: %s capacity       Host space allocated: %s" \
            "$(human_bytes "$logical_bytes")" "$(human_bytes "$allocated_bytes")"
        return 0
    done
    return 1
}

calculate_docker_storage() {
    local docker_type docker_size docker_bytes
    [ -n "${DOCKER_STORAGE_DISPLAY:-}" ] && return 0
    DOCKER_STORAGE_DISPLAY="unavailable"
    DOCKER_STORAGE_BYTES=""
    DOCKER_IMAGES_DISPLAY="-"
    DOCKER_CONTAINER_LAYERS_DISPLAY="-"
    DOCKER_VOLUMES_DISPLAY="-"
    DOCKER_BUILD_CACHE_DISPLAY="-"
    docker info >/dev/null 2>&1 || return 0
    docker_bytes=0
    while IFS=$'\t' read -r docker_type docker_size; do
        [ -n "$docker_size" ] || continue
        docker_size="$(docker_size_to_bytes "$docker_size")"
        [[ "$docker_size" =~ ^[0-9]+$ ]] || continue
        docker_bytes=$((docker_bytes + docker_size))
        case "$docker_type" in
            Images) DOCKER_IMAGES_DISPLAY="$(human_bytes "$docker_size")" ;;
            Containers) DOCKER_CONTAINER_LAYERS_DISPLAY="$(human_bytes "$docker_size")" ;;
            "Local Volumes") DOCKER_VOLUMES_DISPLAY="$(human_bytes "$docker_size")" ;;
            "Build Cache") DOCKER_BUILD_CACHE_DISPLAY="$(human_bytes "$docker_size")" ;;
        esac
    done < <(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null)
    if [ "$docker_bytes" -gt 0 ]; then
        DOCKER_STORAGE_BYTES="$docker_bytes"
        DOCKER_STORAGE_DISPLAY="$(human_bytes "$docker_bytes")"
    fi
}

docker_size_to_bytes() {
    awk '
            /^[0-9.]+([kMGTPE]?i?B)$/ {
                unit = $0
                sub(/^[0-9.]+/, "", unit)
                number = $0
                sub(/[[:alpha:]]+$/, "", number)
                factor = 1
                if (unit == "kB" || unit == "KB") factor = 1000
                else if (unit == "MB") factor = 1000^2
                else if (unit == "GB") factor = 1000^3
                else if (unit == "TB") factor = 1000^4
                else if (unit == "KiB") factor = 1024
                else if (unit == "MiB") factor = 1024^2
                else if (unit == "GiB") factor = 1024^3
                else if (unit == "TiB") factor = 1024^4
                printf "%.0f", number * factor
            }
        ' <<< "$1"
}

docker_persistent_data_bytes() {
    local docker_container="$1" mount_type mount_destination mount_rw mount_bytes total=0
    while IFS=$'\t' read -r mount_type mount_destination mount_rw; do
        [ "$mount_rw" = "true" ] || continue
        case "$mount_type" in volume|bind) ;; *) continue ;; esac
        mount_bytes="$(docker exec -u 0 "$docker_container" /bin/sh -c 'du -sk "$1" 2>/dev/null | awk "NR==1 {printf \"%.0f\\n\", \$1 * 1024}"' wombat-walker "$mount_destination" 2>/dev/null || true)"
        [[ "$mount_bytes" =~ ^[0-9]+$ ]] && total=$((total + mount_bytes))
    done < <(docker inspect "$docker_container" --format '{{range .Mounts}}{{printf "%s\t%s\t%t\n" .Type .Destination .RW}}{{end}}' 2>/dev/null)
    printf '%s\n' "$total"
}

docker_show_mounts() {
    local docker_container="$1" mount_type mount_name mount_source mount_destination mount_rw mount_type_display mount_access mount_storage
    local -a mount_lines
    mapfile -t mount_lines < <(docker inspect "$docker_container" --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%s\t%t\n" .Type .Name .Source .Destination .RW}}{{end}}' 2>/dev/null)
    echo
    printf '%*s\n' 114 '' | tr ' ' '='
    echo "Container storage connections"
    echo "A bind mount is an ordinary server folder. A named volume is persistent Docker-managed data."
    echo
    if [ "${#mount_lines[@]}" -eq 0 ]; then
        echo "  This container has no declared persistent mounts. Its files are in its writable layer."
        return 0
    fi
    printf "  %-13s %-11s %-56s  %s\n" "Type" "Access" "Container path" "Storage"
    printf '%*s\n' 114 '' | tr ' ' '='
    for mount_line in "${mount_lines[@]}"; do
        [ -n "$mount_line" ] || continue
        IFS=$'\t' read -r mount_type mount_name mount_source mount_destination mount_rw <<< "$mount_line"
        case "$mount_type" in
            volume) mount_type_display="named volume"; mount_storage="$mount_name" ;;
            bind) mount_type_display="bind mount"; mount_storage="$mount_source" ;;
            *) mount_type_display="$mount_type"; mount_storage="${mount_name:-$mount_source}" ;;
        esac
        [ "$mount_rw" = "true" ] && mount_access="read/write" || mount_access="read-only"
        printf "  %-13s %-11s %-56s  %s\n" "$mount_type_display" "$mount_access" "$mount_destination" "$mount_storage"
        if [ "$mount_type" = "volume" ]; then
            printf "  %-20s %s\n" "Docker storage path:" "$mount_source"
        fi
    done
    echo
    echo "Read/write means the application can change that storage. It does not mean every file is safe to delete."
}

docker_view_file() {
    local docker_container="$1" docker_path="$2"
    echo
    echo "Safe view: $docker_path"
    echo "Press q to return to Wombat Walker."
    if ! docker exec -u 0 "$docker_container" /bin/sh -c 'cat "$1"' wombat-walker "$docker_path" | /usr/bin/less -R; then
        echo "❌ Walker could not read that file from the live container."
    fi
}

docker_edit_file() {
    local docker_container="$1" docker_name="$2" docker_path="$3" editor="$4" edit_copy before_copy confirmation
    edit_copy="$(mktemp "${TMPDIR:-/tmp}/wombat-walker-container.XXXXXX")" || { echo "❌ Could not create a temporary editor file."; return 1; }
    before_copy="${edit_copy}.before"
    if ! docker exec -u 0 "$docker_container" /bin/sh -c 'cat "$1"' wombat-walker "$docker_path" > "$edit_copy"; then
        echo "❌ Walker could not copy this live container file for editing."
        rm -f -- "$edit_copy"
        return 1
    fi
    cp -- "$edit_copy" "$before_copy"
    "$editor" "$edit_copy"
    if cmp -s -- "$edit_copy" "$before_copy"; then
        echo "No changes were made."
        rm -f -- "$edit_copy" "$before_copy"
        return 0
    fi
    echo
    echo "⚠️  You are about to modify a live Docker container file: $docker_path"
    echo "Changes in the container layer can be lost when $docker_name is recreated."
    echo "For persistent application data, inspect [v] Show storage mounts first."
    read -r -e -p "Type EDIT to write these changes into the container: " confirmation
    if [ "$confirmation" != "EDIT" ]; then
        echo "Docker file edit cancelled; the container was not changed."
        rm -f -- "$edit_copy" "$before_copy"
        return 0
    fi
    if docker exec -i -u 0 "$docker_container" /bin/sh -c 'cat > "$1"' wombat-walker "$docker_path" < "$edit_copy"; then
        echo "Saved into live container: $docker_path"
        echo "Saved scan metadata may now be stale; press [r] to refresh the relevant folder."
    else
        echo "❌ Walker could not write the edited file into the container."
    fi
    rm -f -- "$edit_copy" "$before_copy"
}

docker_writable_data_mount() {
    local docker_container="$1" docker_path="$2" line mount_type mount_name mount_source mount_destination mount_rw best_length=0
    while [[ "$docker_path" == //* ]]; do docker_path="/${docker_path#//}"; done
    DOCKER_CLEANUP_MOUNT_TYPE=""; DOCKER_CLEANUP_MOUNT_NAME=""; DOCKER_CLEANUP_MOUNT_SOURCE=""; DOCKER_CLEANUP_MOUNT_DESTINATION=""
    while IFS=$'\t' read -r mount_type mount_name mount_source mount_destination mount_rw; do
        [ "$mount_rw" = "true" ] || continue
        case "$mount_type" in volume|bind) ;; *) continue ;; esac
        if [ "$docker_path" = "$mount_destination" ] || [[ "$docker_path" = "$mount_destination/"* ]]; then
            if [ "${#mount_destination}" -gt "$best_length" ]; then
                best_length="${#mount_destination}"
                DOCKER_CLEANUP_MOUNT_TYPE="$mount_type"; DOCKER_CLEANUP_MOUNT_NAME="$mount_name"
                DOCKER_CLEANUP_MOUNT_SOURCE="$mount_source"; DOCKER_CLEANUP_MOUNT_DESTINATION="$mount_destination"
            fi
        fi
    done < <(docker inspect "$docker_container" --format '{{range .Mounts}}{{printf "%s\t%s\t%s\t%s\t%t\n" .Type .Name .Source .Destination .RW}}{{end}}' 2>/dev/null)
    [ -n "$DOCKER_CLEANUP_MOUNT_TYPE" ]
}

docker_delete_current_folder() {
    local docker_container="$1" docker_name="$2" docker_path="$3" folder_logical folder_allocated confirmation
    DOCKER_DELETED_FOLDER_PARENT=""
    if ! docker_writable_data_mount "$docker_container" "$docker_path"; then
        echo "❌ Docker cleanup is blocked here. This path is in the container layer or a read-only/unknown mount."
        echo "  Walker deletes Docker data only below a verified read/write named volume or bind mount."
        return 1
    fi
    if [ "$docker_path" = "$DOCKER_CLEANUP_MOUNT_DESTINATION" ]; then
        echo "❌ Docker cleanup will not delete the root of a mounted data store."
        echo "  Open a folder inside $DOCKER_CLEANUP_MOUNT_DESTINATION and delete only that selected folder."
        return 1
    fi
    if ! docker exec -u 0 "$docker_container" /bin/sh -c '[ -d "$1" ] && [ ! -L "$1" ]' wombat-walker "$docker_path" >/dev/null 2>&1; then
        echo "❌ This is no longer a real directory in the running container."
        return 1
    fi
    read -r folder_logical folder_allocated < <(docker exec -u 0 "$docker_container" /bin/sh -c 'du -sk "$1" 2>/dev/null | awk "NR==1 {printf \"%.0f %.0f\\n\", \$1 * 1024, \$1 * 1024}"' wombat-walker "$docker_path")
    [[ "$folder_logical" =~ ^[0-9]+$ ]] || folder_logical=0
    [[ "$folder_allocated" =~ ^[0-9]+$ ]] || folder_allocated=0
    echo
    echo "WARNING: Permanently delete this Docker data folder and everything inside it:"
    echo "  Container: $docker_name"
    echo "  Folder:    $docker_path"
    echo "  Storage:   $DOCKER_CLEANUP_MOUNT_TYPE ${DOCKER_CLEANUP_MOUNT_NAME:-$DOCKER_CLEANUP_MOUNT_SOURCE}"
    echo "  Logical size: $(human_bytes "$folder_logical")    On disk: $(human_bytes "$folder_allocated")"
    echo
    echo "There is no Docker Trash and no restore function. Gone is gone."
    read -r -e -p "Type DELETE to continue: " confirmation
    [ "$confirmation" = "DELETE" ] || { echo "Docker folder deletion cancelled."; return 0; }
    echo "ARE YOU SURE? There is no restore function for Docker cleanup."
    read -r -e -p "Type DELETE FOLDER to permanently delete this folder: " confirmation
    [ "$confirmation" = "DELETE FOLDER" ] || { echo "Docker folder deletion cancelled."; return 0; }
    if docker exec -u 0 "$docker_container" /bin/sh -c 'rm -rf -- "$1"' wombat-walker "$docker_path"; then
        DOCKER_DELETED_FOLDER_PARENT="${docker_path%/*}"
        [ -n "$DOCKER_DELETED_FOLDER_PARENT" ] || DOCKER_DELETED_FOLDER_PARENT="/"
        echo "Permanently deleted Docker folder: $docker_path"
        echo "Expected disk space freed: $(human_bytes "$folder_allocated"). Refresh the saved Docker scan before searching it again."
        return 0
    fi
    echo "❌ Docker could not delete this folder. The application may be using it or its permissions may have changed."
    return 1
}

docker_bulk_delete_files() {
    local docker_container="$1" docker_name="$2" docker_path="$3" selection_mode selection_text raw_extension extension candidate_name selected_number field_index index confirmation confirmation_count
    local total_logical=0 total_allocated=0 selected_logical=0 selected_allocated=0
    local -a fields candidates logical_sizes allocated_sizes
    if ! docker_writable_data_mount "$docker_container" "$docker_path"; then
        echo "❌ Docker cleanup is blocked here. Select a folder inside a verified read/write named volume or bind mount."
        # This is an expected safety refusal, not a script failure.  Returning
        # success keeps the interactive Docker browser open under `set -e`.
        return 0
    fi
    fields=()
    mapfile -d '' -t fields < <(docker exec -u 0 "$docker_container" /bin/sh -c '
        directory=$1
        for child in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
            [ -f "$child" ] && [ ! -L "$child" ] || continue
            set -- $(stat -c "%s %b" "$child" 2>/dev/null || echo "0 0")
            printf "%s\0%s\0%s\0" "$child" "$1" "$(( $2 * 512 ))"
        done
    ' wombat-walker "$docker_path" 2>/dev/null)
    candidates=(); logical_sizes=(); allocated_sizes=()
    for ((field_index=0; field_index<${#fields[@]}; field_index+=3)); do
        candidates+=("${fields[$field_index]}"); logical_sizes+=("${fields[$((field_index + 1))]}"); allocated_sizes+=("${fields[$((field_index + 2))]}")
        total_logical=$((total_logical + fields[$((field_index + 1))])); total_allocated=$((total_allocated + fields[$((field_index + 2))]))
    done
    [ "${#candidates[@]}" -gt 0 ] || { echo "No direct regular files are available for Docker cleanup here."; return 0; }
    echo
    echo "Docker file cleanup preview — verified writable ${DOCKER_CLEANUP_MOUNT_TYPE} data"
    echo "Container: $docker_name    Folder: $docker_path"
    printf "  %-5s%-42s %12s  %12s\n" "No." "Name" "Logical" "On disk"
    for ((index=0; index<${#candidates[@]}; index++)); do
        candidate_name="${candidates[$index]##*/}"; [ "${#candidate_name}" -le 42 ] || candidate_name="${candidate_name:0:39}..."
        printf "  %-5s%-42s %12s  %12s\n" "[$((index + 1))]" "$candidate_name" "$(human_bytes "${logical_sizes[$index]}")" "$(human_bytes "${allocated_sizes[$index]}")"
    done
    echo "  All direct file data: $(human_bytes "$total_logical") logical | $(human_bytes "$total_allocated") on disk"
    while true; do
        echo "  [a] All files  [n] Numbers/ranges  [t] Exact extension  [q] Cancel"
        read -r -e -p "> " selection_mode
        case "$selection_mode" in
            a|A) BULK_SELECTED_INDICES=(); for ((index=1; index<=${#candidates[@]}; index++)); do BULK_SELECTED_INDICES+=("$index"); done; break ;;
            n|N)
                read -r -e -p "File numbers or ranges: " selection_text
                if bulk_parse_selection "$selection_text" "${#candidates[@]}"; then
                    break
                fi
                echo "❌ Enter valid file numbers or ranges, for example 1,3,7 or 1-9."
                ;;
            t|T)
                read -r -e -p "Exact extension (examples: wav, .wav, *.wav): " raw_extension
                extension="${raw_extension#*.}"; extension="${extension#.}"
                if ! [[ "$extension" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
                    echo "❌ Enter one exact extension."
                    continue
                fi
                BULK_SELECTED_INDICES=()
                for ((index=1; index<=${#candidates[@]}; index++)); do candidate_name="${candidates[$((index - 1))]##*/}"; [[ "${candidate_name,,}" == *."${extension,,}" ]] && BULK_SELECTED_INDICES+=("$index"); done
                if [ "${#BULK_SELECTED_INDICES[@]}" -gt 0 ]; then
                    break
                fi
                echo "No direct .$extension files were found."
                ;;
            q|Q|"") return 0 ;;
            *) echo "❌ Choose a, n, t, or q." ;;
        esac
    done
    for selected_number in "${BULK_SELECTED_INDICES[@]}"; do index=$((selected_number - 1)); selected_logical=$((selected_logical + logical_sizes[$index])); selected_allocated=$((selected_allocated + allocated_sizes[$index])); done
    echo "Selected: ${#BULK_SELECTED_INDICES[@]} files — $(human_bytes "$selected_logical") logical | $(human_bytes "$selected_allocated") on disk"
    echo "WARNING: There is no Docker Trash and no restore function. Gone is gone."
    read -r -e -p "Type DELETE to continue: " confirmation
    [ "$confirmation" = "DELETE" ] || { echo "Docker file deletion cancelled."; return 0; }
    read -r -e -p "Type DELETE ${#BULK_SELECTED_INDICES[@]} to permanently delete these files: " confirmation_count
    [ "$confirmation_count" = "DELETE ${#BULK_SELECTED_INDICES[@]}" ] || { echo "Docker file deletion cancelled."; return 0; }
    for selected_number in "${BULK_SELECTED_INDICES[@]}"; do
        index=$((selected_number - 1))
        docker exec -u 0 "$docker_container" /bin/sh -c '[ -f "$1" ] && [ ! -L "$1" ] && rm -f -- "$1"' wombat-walker "${candidates[$index]}" || echo "❌ Could not delete: ${candidates[$index]}"
    done
    echo "Permanent Docker cleanup complete. Expected disk space freed: $(human_bytes "$selected_allocated"). Refresh saved Docker scans before searching."
}

docker_recursive_extension_cleanup() {
    local docker_container="$1" docker_name="$2" docker_path="$3" raw_extension extension field_index index candidate_name confirmation confirmation_count
    local total_logical=0 total_allocated=0 display_limit=100
    local -a fields candidates logical_sizes allocated_sizes

    if ! docker_writable_data_mount "$docker_container" "$docker_path"; then
        echo "❌ Docker cleanup is blocked here. Select a folder inside a verified read/write named volume or bind mount."
        return 0
    fi
    echo
    echo "Recursive Docker cleanup searches this folder and every subfolder for one exact extension."
    echo "Only regular files are included. Symbolic links, directories, and container-layer files are excluded."
    read -r -e -p "Exact extension to preview (examples: wav, .wav, *.wav): " raw_extension
    extension="${raw_extension#*.}"; extension="${extension#.}"
    if ! [[ "$extension" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
        echo "❌ Enter one exact extension."
        return 0
    fi

    fields=()
    mapfile -d '' -t fields < <(docker exec -u 0 "$docker_container" /bin/sh -c '
        directory=$1 extension=$2
        find "$directory" -type f ! -type l -name "*.$extension" -exec /bin/sh -c '\''
            for child do
                logical=$(stat -c "%s" "$child" 2>/dev/null || printf 0)
                blocks=$(stat -c "%b" "$child" 2>/dev/null || printf 0)
                printf "%s\\0%s\\0%s\\0" "$child" "$logical" "$((blocks * 512))"
            done
        '\'' wombat-walker {} +
    ' wombat-walker "$docker_path" "$extension" 2>/dev/null)
    candidates=(); logical_sizes=(); allocated_sizes=()
    for ((field_index=0; field_index<${#fields[@]}; field_index+=3)); do
        candidates+=("${fields[$field_index]}"); logical_sizes+=("${fields[$((field_index + 1))]}"); allocated_sizes+=("${fields[$((field_index + 2))]}")
        total_logical=$((total_logical + fields[$((field_index + 1))])); total_allocated=$((total_allocated + fields[$((field_index + 2))]))
    done
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "No .$extension regular files were found below $docker_path."
        return 0
    fi
    echo
    echo "Recursive Docker cleanup preview — verified writable ${DOCKER_CLEANUP_MOUNT_TYPE} data"
    echo "Container: $docker_name    Starting folder: $docker_path"
    printf "  %-5s%-58s %12s  %12s\n" "No." "Path" "Logical" "On disk"
    for ((index=0; index<${#candidates[@]} && index<display_limit; index++)); do
        candidate_name="${candidates[$index]#"$docker_path"/}"; [ "${#candidate_name}" -le 58 ] || candidate_name="...${candidate_name: -55}"
        printf "  %-5s%-58s %12s  %12s\n" "[$((index + 1))]" "$candidate_name" "$(human_bytes "${logical_sizes[$index]}")" "$(human_bytes "${allocated_sizes[$index]}")"
    done
    if [ "${#candidates[@]}" -gt "$display_limit" ]; then
        echo "  Preview shows the first $display_limit paths; all ${#candidates[@]} matching files are included below."
    fi
    echo "  Matches: ${#candidates[@]} regular .$extension files"
    echo "  Total file data: $(human_bytes "$total_logical") logical | $(human_bytes "$total_allocated") on disk"
    echo
    echo "WARNING: This permanently deletes every displayed/matched .$extension file below this folder."
    echo "There is no Docker Trash and no restore function. Gone is gone."
    read -r -e -p "Type DELETE to continue: " confirmation
    [ "$confirmation" = "DELETE" ] || { echo "Recursive Docker cleanup cancelled; no files were changed."; return 0; }
    read -r -e -p "Type DELETE ${#candidates[@]} $extension to permanently delete these files: " confirmation_count
    [ "$confirmation_count" = "DELETE ${#candidates[@]} $extension" ] || { echo "Recursive Docker cleanup cancelled; no files were changed."; return 0; }
    for ((index=0; index<${#candidates[@]}; index++)); do
        docker exec -u 0 "$docker_container" /bin/sh -c '[ -f "$1" ] && [ ! -L "$1" ] && rm -f -- "$1"' wombat-walker "${candidates[$index]}" || echo "❌ Could not delete: ${candidates[$index]}"
    done
    echo "Recursive Docker cleanup complete. Expected disk space freed: $(human_bytes "$total_allocated"). Refresh saved Docker scans before searching."
}

docker_file_action_menu() {
    local docker_container="$1" docker_name="$2" docker_path="$3" action editor
    if ! docker exec -u 0 "$docker_container" /bin/sh -c '[ -f "$1" ] && [ ! -L "$1" ]' wombat-walker "$docker_path" >/dev/null 2>&1; then
        echo "❌ Cannot open this selection because it is no longer a regular non-symlink file."
        return 1
    fi
    while true; do
        echo
        echo "Selected container file: $docker_path"
        echo "Container: $docker_name"
        echo "  [1] View safely"
        echo "  [2] Edit with preferred editor ($(editor_label "$PREFERRED_EDITOR"))"
        echo "  [3] Choose preferred editor"
        echo "  [4] Edit once with another editor"
        echo "  [q] Return to container browser"
        read -r -e -p "> " action
        case "$action" in
            q|Q|"") return 0 ;;
            1) docker_view_file "$docker_container" "$docker_path" ;;
            2) editor="$(editor_path "$PREFERRED_EDITOR")" ;;
            3) choose_preferred_editor; continue ;;
            4)
                choose_one_off_editor
                [ -n "${ONE_OFF_EDITOR:-}" ] || continue
                editor="$(editor_path "$ONE_OFF_EDITOR")"
                ;;
            *) echo "❌ Enter 1, 2, 3, 4, or q."; continue ;;
        esac
        if [ -z "${editor:-}" ] || [ ! -x "$editor" ]; then
            echo "❌ The selected editor is not available on this server."
            continue
        fi
        docker_edit_file "$docker_container" "$docker_name" "$docker_path" "$editor"
    done
}

browse_docker_container() {
    local docker_container="$1" docker_name="$2" docker_current="${3:-/}" docker_choice docker_manual docker_target docker_parent
    local docker_running docker_fields_index docker_kind docker_path docker_logical docker_blocks docker_mtime docker_name_display docker_modified docker_info docker_sort_key docker_sort_value docker_sort_choice docker_record_index
    local docker_total docker_page=0 docker_start docker_end docker_selection docker_total_key docker_total_record docker_total_logical docker_total_allocated docker_total_files docker_total_coverage docker_total_scanned
    local -a docker_fields docker_entries docker_visible docker_sort_records docker_sorted_records docker_ordered_fields docker_total_fields
    declare -A docker_folder_total_cache=()

    docker_running="$(docker inspect "$docker_container" --format '{{.State.Running}}' 2>/dev/null || true)"
    if [ "$docker_running" != "true" ]; then
        echo "❌ $docker_name is not running, so its live container filesystem cannot be browsed."
        echo "  You can still inspect its persistent mounts below."
        docker_show_mounts "$docker_container"
        read -r -e -p "Press Enter to return to Docker containers. " _
        return 0
    fi

    while true; do
        if ! docker exec -u 0 "$docker_container" /bin/sh -c '[ -d "$1" ]' wombat-walker "$docker_current" >/dev/null 2>&1; then
            echo "❌ Walker could not read $docker_current inside $docker_name."
            echo "  The image may not provide /bin/sh, or this path is no longer available."
            read -r -e -p "Press Enter to return to Docker containers. " _
            return 0
        fi
        docker_fields=()
        mapfile -d '' -t docker_fields < <(docker exec -u 0 "$docker_container" /bin/sh -c '
            directory=$1
            for child in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
                [ -e "$child" ] || [ -L "$child" ] || continue
                while [ "${child#//}" != "$child" ]; do child="/${child#//}"; done
                if [ -L "$child" ]; then kind=sym
                elif [ -d "$child" ]; then kind=dir
                elif [ -f "$child" ]; then kind=file
                else kind=other
                fi
                if [ "$kind" = dir ]; then
                    logical=$(du -sk "$child" 2>/dev/null | awk "NR == 1 { printf \"%.0f\\n\", \$1 * 1024 }")
                    blocks=$logical
                else
                    set -- $(stat -c "%s %b %Y" "$child" 2>/dev/null || echo "0 0 0")
                    logical=$1; blocks=$(( $2 * 512 )); modified=$3
                fi
                [ "$kind" = dir ] && modified=$(stat -c "%Y" "$child" 2>/dev/null || echo 0)
                printf "%s\0%s\0%s\0%s\0%s\0" "$kind" "$child" "${logical:-0}" "${blocks:-0}" "${modified:-0}"
            done
        ' wombat-walker "$docker_current" 2>/dev/null)
        docker_entries=()
        for ((docker_fields_index=0; docker_fields_index<${#docker_fields[@]}; docker_fields_index+=5)); do
            docker_entries+=("${docker_fields[$((docker_fields_index + 1))]}")
        done
        docker_sort_records=()
        for ((docker_fields_index=0; docker_fields_index<${#docker_fields[@]}; docker_fields_index+=5)); do
            case "$DOCKER_FILE_SORT_ORDER" in
                largest|smallest)
                    docker_sort_value="${docker_fields[$((docker_fields_index + 2))]}"
                    [[ "$docker_sort_value" =~ ^[0-9]+$ ]] || docker_sort_value=0
                    docker_sort_key="$(printf '%020d' "$docker_sort_value")"
                    ;;
                updated)
                    docker_sort_value="${docker_fields[$((docker_fields_index + 4))]}"
                    [[ "$docker_sort_value" =~ ^[0-9]+$ ]] || docker_sort_value=0
                    docker_sort_key="$(printf '%020d' "$docker_sort_value")"
                    ;;
                *) docker_sort_key="${docker_fields[$((docker_fields_index + 1))]}" ;;
            esac
            docker_sort_records+=("$docker_sort_key"$'\t'"$docker_fields_index")
        done
        if [ "${#docker_sort_records[@]}" -gt 0 ]; then
            if [ "$DOCKER_FILE_SORT_ORDER" = "smallest" ]; then
                mapfile -t docker_sorted_records < <(printf '%s\n' "${docker_sort_records[@]}" | LC_ALL=C sort -t $'\t' -k1,1n)
            elif [ "$DOCKER_FILE_SORT_ORDER" = "largest" ] || [ "$DOCKER_FILE_SORT_ORDER" = "updated" ]; then
                mapfile -t docker_sorted_records < <(printf '%s\n' "${docker_sort_records[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr)
            else
                mapfile -t docker_sorted_records < <(printf '%s\n' "${docker_sort_records[@]}" | LC_ALL=C sort -t $'\t' -k1,1f)
            fi
            docker_ordered_fields=()
            for docker_sort_key in "${docker_sorted_records[@]}"; do
                docker_record_index="${docker_sort_key#*$'\t'}"
                for ((i=0; i<5; i++)); do docker_ordered_fields+=("${docker_fields[$((docker_record_index + i))]}"); done
            done
            docker_fields=("${docker_ordered_fields[@]}")
            docker_entries=()
            for ((docker_fields_index=0; docker_fields_index<${#docker_fields[@]}; docker_fields_index+=5)); do docker_entries+=("${docker_fields[$((docker_fields_index + 1))]}"); done
        fi
        docker_total="${#docker_entries[@]}"
        if [ "$docker_total" -eq 0 ]; then docker_page=0
        elif [ $((docker_page * ITEMS_PER_PAGE)) -ge "$docker_total" ]; then docker_page=$(((docker_total - 1) / ITEMS_PER_PAGE)); fi
        docker_start=$((docker_page * ITEMS_PER_PAGE)); docker_end=$((docker_start + ITEMS_PER_PAGE))
        [ "$docker_end" -gt "$docker_total" ] && docker_end="$docker_total"
        docker_total_key="$docker_container:$docker_current"
        if [ -z "${docker_folder_total_cache[$docker_total_key]+saved}" ]; then
            docker_total_fields=()
            mapfile -d '' -t docker_total_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-folder-total "$WALKER_DATABASE" "$docker_container" "$docker_current" 2>/dev/null || true)
            docker_folder_total_cache[$docker_total_key]="$(IFS=$'\t'; echo "${docker_total_fields[*]}")"
        fi
        docker_total_record="${docker_folder_total_cache[$docker_total_key]}"
        IFS=$'\t' read -r docker_total_logical docker_total_allocated docker_total_files docker_total_coverage docker_total_scanned <<< "$docker_total_record"

        echo
        echo "=============================================================================================="
        echo "Docker container: $docker_name"
        echo "Path inside container: $docker_current"
        echo "Order: $DOCKER_FILE_SORT_ORDER    This is a read-only view of a live container. Inspect mounts before deciding where data lives."
        echo "A saved scan records metadata only for fast later search; it does not copy, alter, or read file contents."
        echo "=============================================================================================="
        printf "  %-5s%-8s%-32s %12s  %12s  %-16s\n" "No." "Type" "Name" "Logical size" "On disk" "Last updated"
        docker_selection=1
        for ((docker_fields_index=docker_start * 5; docker_fields_index<docker_end * 5; docker_fields_index+=5)); do
            docker_kind="${docker_fields[$docker_fields_index]}"; docker_path="${docker_fields[$((docker_fields_index + 1))]}"
            docker_logical="${docker_fields[$((docker_fields_index + 2))]}"; docker_blocks="${docker_fields[$((docker_fields_index + 3))]}"; docker_mtime="${docker_fields[$((docker_fields_index + 4))]}"
            docker_name_display="${docker_path##*/}"
            [ "${#docker_name_display}" -le 32 ] || docker_name_display="${docker_name_display:0:29}..."
            docker_modified="$(date -d "@$docker_mtime" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
            printf "  %-5s%-8s%-32s %12s  %12s  %-16s\n" "[$docker_selection]" "$docker_kind" "$docker_name_display" "$(human_bytes "$docker_logical")" "$(human_bytes "$docker_blocks")" "$docker_modified"
            docker_selection=$((docker_selection + 1))
        done
        echo
        if [ -n "$docker_total_files" ]; then
            echo "  Cached file total in this folder: $(human_bytes "$docker_total_logical") logical  |  $(human_bytes "$docker_total_allocated") on disk"
            echo "  $docker_total_files files  |  covered by saved scan of $docker_total_coverage ($docker_total_scanned)"
        else
            echo "  Cached file total in this folder: unavailable — press [r] to save a scan covering this folder."
        fi
        if [ "$docker_total" -gt "$ITEMS_PER_PAGE" ]; then
            echo
            printf "  %-34s%42s\n" "[n] Next page    [p] Previous page" "Showing $((docker_start + 1))-$docker_end of $docker_total items"
        fi
        echo
        printf "  %-32s%-32s%s\n" "[u] Up one folder" "[m] Type a container path" "[o] Change display order"
        printf "  %-32s%-32s%s\n" "[r] Save scan of this folder" "[s] Search saved Docker scans" "[v] Show storage mounts"
        printf "  %-32s%-32s%s\n" "[b] Delete files here" "[x] Delete current folder" "[w] Recursive delete by extension"
        printf "  %-32s%-32s%s\n" "" "" "[q] Return to containers"
        read -r -e -p "> " docker_choice
        case "$docker_choice" in
            q|Q|"") return 0 ;;
            u|U) [ "$docker_current" = "/" ] || docker_current="${docker_current%/*}"; [ -n "$docker_current" ] || docker_current="/"; docker_page=0 ;;
            n|N) [ "$docker_end" -lt "$docker_total" ] && docker_page=$((docker_page + 1)) || echo "❌ This is the last page." ;;
            p|P) [ "$docker_page" -gt 0 ] && docker_page=$((docker_page - 1)) || echo "❌ This is the first page." ;;
            m|M)
                read -r -e -p "Container path: " docker_manual
                case "$docker_manual" in /*) docker_current="$docker_manual"; docker_page=0 ;; *) echo "❌ Enter an absolute container path beginning with /." ;; esac
                ;;
            o|O)
                echo "  [1] Alphabetical  [2] Largest first  [3] Smallest first  [4] Most recently updated first"
                read -r -e -p "> " docker_sort_choice
                case "$docker_sort_choice" in
                    1) DOCKER_FILE_SORT_ORDER="alphabetical" ;;
                    2) DOCKER_FILE_SORT_ORDER="largest" ;;
                    3) DOCKER_FILE_SORT_ORDER="smallest" ;;
                    4) DOCKER_FILE_SORT_ORDER="updated" ;;
                    *) echo "❌ Enter 1, 2, 3, or 4." ;;
                esac
                docker_page=0
                ;;
            r|R)
                echo "Saving a read-only Docker metadata scan of: $docker_current"
                if python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-scan "$WALKER_DATABASE" "$docker_container" "$docker_current"; then
                    docker_folder_total_cache=()
                else
                    echo "❌ Docker scan failed."
                fi
                ;;
            s|S) docker_search_menu "$docker_container" "$docker_name" "$docker_current" ;;
            v|V) docker_show_mounts "$docker_container"; read -r -e -p "Press Enter to return to the container. " _ ;;
            h|H) docker_help_screen; read -r -e -p "Press Enter to return to the container. " _ ;;
            b|B) docker_bulk_delete_files "$docker_container" "$docker_name" "$docker_current"; docker_folder_total_cache=() ;;
            w|W) docker_recursive_extension_cleanup "$docker_container" "$docker_name" "$docker_current"; docker_folder_total_cache=() ;;
            x|X)
                docker_parent="${docker_current%/*}"
                [ -n "$docker_parent" ] || docker_parent="/"
                docker_delete_current_folder "$docker_container" "$docker_name" "$docker_current"
                docker_folder_total_cache=()
                if [ -n "${DOCKER_DELETED_FOLDER_PARENT:-}" ]; then
                    docker_current="$DOCKER_DELETED_FOLDER_PARENT"
                    docker_page=0
                elif ! docker exec -u 0 "$docker_container" /bin/sh -c '[ -d "$1" ]' wombat-walker "$docker_current" >/dev/null 2>&1; then
                    docker_current="$docker_parent"
                    docker_page=0
                fi
                ;;
            *)
                if [[ "$docker_choice" =~ ^[0-9]+$ ]] && [ "$docker_choice" -ge 1 ] && [ "$docker_choice" -le $((docker_end - docker_start)) ]; then
                    docker_target="${docker_fields[$(((docker_start + docker_choice - 1) * 5 + 1))]}"
                    docker_kind="${docker_fields[$(((docker_start + docker_choice - 1) * 5))]}"
                    if [ "$docker_kind" = dir ]; then
                        docker_current="$docker_target"; docker_page=0
                    else
                        docker_file_action_menu "$docker_container" "$docker_name" "$docker_target"
                    fi
                else
                    echo "❌ Enter a listed number, u, m, o, r, s, v, b, w, x, n, p, or q."
                fi
                ;;
        esac
    done
}

docker_search_choose_container() {
    local docker_choice docker_line docker_id docker_name docker_status docker_image docker_size docker_page=0 docker_start docker_end
    local -a docker_lines
    DOCKER_SEARCH_SELECTED_ID=""
    DOCKER_SEARCH_SELECTED_NAME=""
    mapfile -t docker_lines < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}' 2>/dev/null)
    [ "${#docker_lines[@]}" -gt 0 ] || { echo "❌ No Docker containers are available to search."; return 1; }
    while true; do
        docker_start=$((docker_page * ITEMS_PER_PAGE)); docker_end=$((docker_start + ITEMS_PER_PAGE))
        [ "$docker_end" -gt "${#docker_lines[@]}" ] && docker_end="${#docker_lines[@]}"
        echo
        echo "Choose a Docker container to search"
        printf '%*s\n' 114 '' | tr ' ' '='
        printf "  %-5s%-13s%-25s%-20s%-28s\n" "No." "ID" "Container" "Status" "Image"
        for ((docker_choice=docker_start; docker_choice<docker_end; docker_choice++)); do
            IFS=$'\t' read -r docker_id docker_name docker_status docker_image docker_size <<< "${docker_lines[$docker_choice]}"
            [ "${#docker_name}" -le 24 ] || docker_name="${docker_name:0:21}..."
            [ "${#docker_status}" -le 19 ] || docker_status="${docker_status:0:16}..."
            [ "${#docker_image}" -le 27 ] || docker_image="${docker_image:0:24}..."
            printf "  %-5s%-13s%-25s%-20s%-28s\n" "[$((docker_choice + 1))]" "${docker_id:0:12}" "$docker_name" "$docker_status" "$docker_image"
        done
        echo
        printf "  %-34s%-34s%s\n" "[n] Next page" "[p] Previous page" "[q] Cancel"
        echo
        read -r -e -p "Choose a container number, n/p/q: " docker_choice
        case "$docker_choice" in
            q|Q|"") return 0 ;;
            n|N)
                [ "$docker_end" -lt "${#docker_lines[@]}" ] && docker_page=$((docker_page + 1)) || echo "❌ This is the last container page."
                ;;
            p|P)
                [ "$docker_page" -gt 0 ] && docker_page=$((docker_page - 1)) || echo "❌ This is the first container page."
                ;;
            *)
                if [[ "$docker_choice" =~ ^[0-9]+$ ]] && [ "$docker_choice" -ge $((docker_start + 1)) ] && [ "$docker_choice" -le "$docker_end" ]; then
                    IFS=$'\t' read -r DOCKER_SEARCH_SELECTED_ID DOCKER_SEARCH_SELECTED_NAME docker_status docker_image docker_size <<< "${docker_lines[$((docker_choice - 1))]}"
                    return 0
                fi
                echo "❌ Enter a displayed container number, n, p, or q."
                ;;
        esac
    done
}

docker_search_menu() {
    local docker_search_words docker_result_number docker_result_path docker_result_parent docker_scope_choice docker_search_order docker_search_order_choice docker_refresh_choice docker_running docker_refresh_path docker_search_offset docker_search_min_size docker_search_max_size
    local scoped_container="${1:--}" scoped_name="${2:-}" scoped_folder="${3:--}"
    local -a docker_result_fields
    if [ "$scoped_container" != "-" ]; then
        echo
        echo "Where do you want to search?"
        echo "  [1] This container only: $scoped_name"
        echo "  [2] This folder and all descendants: $scoped_folder"
        echo "  [3] Search every saved Docker container scan"
        echo "  [4] Choose another Docker container"
        echo "  [q] Cancel"
        read -r -e -p "> " docker_scope_choice
        case "$docker_scope_choice" in
            1) scoped_folder="-" ;;
            2) ;;
            3) scoped_container="-"; scoped_folder="-" ;;
            4)
                docker_search_choose_container || return 0
                [ -n "$DOCKER_SEARCH_SELECTED_ID" ] || return 0
                scoped_container="$DOCKER_SEARCH_SELECTED_ID"; scoped_name="$DOCKER_SEARCH_SELECTED_NAME"; scoped_folder="-"
                ;;
            q|Q|"") return 0 ;;
            *) echo "❌ Enter 1, 2, 3, 4, or q."; return 0 ;;
        esac
    else
        echo
        echo "Where do you want to search?"
        echo "  [1] Search every saved Docker container scan"
        echo "  [2] Choose a Docker container"
        echo "  [q] Cancel"
        read -r -e -p "> " docker_scope_choice
        case "$docker_scope_choice" in
            1) scoped_folder="-" ;;
            2)
                docker_search_choose_container || return 0
                [ -n "$DOCKER_SEARCH_SELECTED_ID" ] || return 0
                scoped_container="$DOCKER_SEARCH_SELECTED_ID"; scoped_name="$DOCKER_SEARCH_SELECTED_NAME"; scoped_folder="-"
                ;;
            q|Q|"") return 0 ;;
            *) echo "❌ Enter 1, 2, or q."; return 0 ;;
        esac
    fi
    if [ "$scoped_container" != "-" ]; then
        docker_running="$(docker inspect "$scoped_container" --format '{{.State.Running}}' 2>/dev/null || true)"
        if [ "$docker_running" = "true" ]; then
            read -r -e -p "Refresh this container's saved search index before searching? [Y/n] " docker_refresh_choice
            case "$docker_refresh_choice" in
                n|N|no|NO) ;;
                *)
                    docker_refresh_path="$scoped_folder"
                    [ "$docker_refresh_path" = "-" ] && docker_refresh_path="/"
                    echo "Refreshing saved Docker search index for: ${scoped_name:-$scoped_container}"
                    if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-scan "$WALKER_DATABASE" "$scoped_container" "$docker_refresh_path"; then
                        echo "❌ Could not refresh this container's search index. Search was cancelled."
                        return 0
                    fi
                    ;;
            esac
        else
            echo "This container is not running, so its saved search index cannot be refreshed."
        fi
    else
        read -r -e -p "Refresh all running containers before searching? [Y/n] " docker_refresh_choice
        case "$docker_refresh_choice" in
            n|N|no|NO) ;;
            *) docker_scan_all_running ;;
        esac
    fi
    read -r -e -p "Enter Docker search words (q to cancel): " docker_search_words
    case "$docker_search_words" in q|Q|"") return 0 ;; esac
    docker_search_order="relevance"
    docker_search_offset=0
    docker_search_min_size=""
    docker_search_max_size=""
    while true; do
        echo
        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-search "$WALKER_DATABASE" "$docker_search_words" "$SEARCH_LIMIT" "$docker_search_offset" "$scoped_container" "$scoped_folder" "$docker_search_order" "$docker_search_min_size" "$docker_search_max_size"; then
            echo "❌ Docker saved-search request failed."
            return 0
        fi
        echo
        echo "[n] Next page   [p] Previous page   [o] Change result order   [f] Refine search   [r] New search words  [q] Return"
        read -r -e -p "Open result number, or choose n/p/o/f/r/q: " docker_result_number
        case "$docker_result_number" in
            q|Q|"") return 0 ;;
            n|N) docker_search_offset=$((docker_search_offset + SEARCH_LIMIT)); continue ;;
            p|P)
                if [ "$docker_search_offset" -ge "$SEARCH_LIMIT" ]; then docker_search_offset=$((docker_search_offset - SEARCH_LIMIT)); else echo "❌ This is the first search-results page."; fi
                continue
                ;;
            o|O)
                echo "  [1] Search relevance  [2] Largest first  [3] Smallest first  [4] Most recently updated"
                read -r -e -p "> " docker_search_order_choice
                case "$docker_search_order_choice" in
                    1) docker_search_order="relevance" ;; 2) docker_search_order="largest" ;;
                    3) docker_search_order="smallest" ;; 4) docker_search_order="updated" ;;
                    *) echo "❌ Enter 1, 2, 3, or 4." ;;
                esac
                docker_search_offset=0
                continue
                ;;
            f|F)
                read -r -e -p "Minimum logical size (blank for none, e.g. 100MB): " docker_search_min_size
                read -r -e -p "Maximum logical size (blank for none): " docker_search_max_size
                docker_search_offset=0
                continue
                ;;
            r|R)
                read -r -e -p "Enter new Docker search words (q to cancel): " docker_search_words
                case "$docker_search_words" in q|Q|"") return 0 ;; esac
                docker_search_min_size=""; docker_search_max_size=""; docker_search_offset=0
                continue
                ;;
        esac
        if ! [[ "$docker_result_number" =~ ^[0-9]+$ ]] || [ "$docker_result_number" -le "$docker_search_offset" ] || [ "$docker_result_number" -gt $((docker_search_offset + SEARCH_LIMIT)) ]; then
            echo "❌ Enter a result number shown on this page, n, p, o, f, r, or q."
            continue
        fi
        docker_result_fields=()
        mapfile -d '' -t docker_result_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-search-path "$WALKER_DATABASE" "$docker_search_words" "$docker_result_number" "$scoped_container" "$scoped_folder" "$docker_search_order" "$docker_search_min_size" "$docker_search_max_size" 2>/dev/null || true)
        if [ "${#docker_result_fields[@]}" -ne 4 ]; then
            echo "❌ That result is outside the displayed Docker search results."
            continue
        fi
        docker_result_path="${docker_result_fields[3]}"
        if [[ "$docker_result_path" != /* ]]; then
            echo "❌ The saved Docker path is invalid."
            continue
        fi
        docker_result_parent="$docker_result_path"
        [ "${docker_result_fields[2]}" = "directory" ] || docker_result_parent="$(dirname "$docker_result_path")"
        browse_docker_container "${docker_result_fields[0]}" "${docker_result_fields[1]}" "$docker_result_parent"
        return 0
    done
}

docker_scan_all_running() {
    local confirmation docker_line docker_id docker_name total_containers running_containers position failures session_started
    local -a running_lines
    mapfile -t running_lines < <(docker ps --format '{{.ID}}\t{{.Names}}' 2>/dev/null)
    running_containers="${#running_lines[@]}"
    total_containers="$(docker ps -aq 2>/dev/null | wc -l)"
    [ -n "$total_containers" ] || total_containers=0
    if [ "$running_containers" -eq 0 ]; then
        echo "No running containers are available for a live scan."
        echo "Stopped containers are not scanned because Docker cannot safely use docker exec on them."
        return 0
    fi
    echo
    echo "This will save a read-only metadata scan of / in all $running_containers running container(s)."
    echo "It records paths, types, sizes, and timestamps only; it does not read file contents or change Docker."
    if [ "$total_containers" -gt "$running_containers" ]; then
        echo "$((total_containers - running_containers)) stopped container(s) will be skipped."
    fi
    read -r -e -p "Start all running-container scans? [y/N] " confirmation
    case "$confirmation" in y|Y|yes|YES) ;; *) echo "Docker all-container scan cancelled."; return 0 ;; esac
    session_started="$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"
    failures=0; position=0
    for docker_line in "${running_lines[@]}"; do
        IFS=$'\t' read -r docker_id docker_name <<< "$docker_line"
        position=$((position + 1))
        echo
        printf '%*s\n' 98 '' | tr ' ' '='
        echo "Docker scan — container $position of $running_containers: $docker_name"
        printf '%*s\n' 98 '' | tr ' ' '='
        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-scan "$WALKER_DATABASE" "$docker_id" /; then
            failures=$((failures + 1))
            echo "❌ Scan failed for: $docker_name — continuing with the remaining containers."
        fi
    done
    echo
    echo "All-container Docker scan finished: $((running_containers - failures)) of $running_containers running container(s) saved."
    python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-session-summary "$WALKER_DATABASE" "$session_started" || true
    [ "$failures" -eq 0 ] || echo "Failures: $failures. Search results remain available for successfully scanned containers."
}

DOCKER_LOCKS_FILE="${WOMBAT_WALKER_DOCKER_LOCKS:-$HOME/.local/state/wombat-walker/docker-locks}"

docker_lock_state() {
    local docker_id="$1" docker_status="$2" saved_state
    saved_state="$(awk -F '\t' -v id="$docker_id" '$1 == id { print $2; exit }' "$DOCKER_LOCKS_FILE" 2>/dev/null || true)"
    if [[ "$docker_status" == Up* ]]; then
        printf 'locked'
    elif [ "$saved_state" = "locked" ] || [ "$saved_state" = "unlocked" ]; then
        printf '%s' "$saved_state"
    else
        printf 'locked'
    fi
}

docker_set_lock_state() {
    local docker_id="$1" new_state="$2" lock_dir temp_file
    lock_dir="$(dirname "$DOCKER_LOCKS_FILE")"
    mkdir -p "$lock_dir" 2>/dev/null || return 1
    temp_file="$(mktemp "${DOCKER_LOCKS_FILE}.XXXXXX")" || return 1
    awk -F '\t' -v id="$docker_id" '$1 != id { print }' "$DOCKER_LOCKS_FILE" 2>/dev/null > "$temp_file" || true
    printf '%s\t%s\n' "$docker_id" "$new_state" >> "$temp_file"
    chmod 600 "$temp_file" 2>/dev/null || true
    mv -f -- "$temp_file" "$DOCKER_LOCKS_FILE"
}

docker_purge_unlocked_stopped() {
    local docker_line docker_id docker_name docker_status docker_image docker_size docker_state confirmation removed=0 locked=0
    local -a purge_lines purge_ids purge_names
    mapfile -t purge_lines < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}' 2>/dev/null)
    purge_ids=(); purge_names=()
    for docker_line in "${purge_lines[@]}"; do
        IFS=$'\t' read -r docker_id docker_name docker_status docker_image docker_size <<< "$docker_line"
        [[ "$docker_status" == Up* ]] && continue
        docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
        if [ "$docker_state" = "locked" ]; then
            locked=$((locked + 1))
        else
            purge_ids+=("$docker_id"); purge_names+=("$docker_name")
        fi
    done
    if [ "${#purge_ids[@]}" -eq 0 ]; then
        echo
        echo "No unlocked stopped containers are available for removal. Locked containers skipped: $locked."
        return 0
    fi
    echo "The following unlocked stopped containers will be removed:"
    printf '  %s\n' "${purge_names[@]}"
    echo "Images and named volumes will not be removed."
    read -r -e -p "Type PURGE to confirm: " confirmation
    [ "$confirmation" = "PURGE" ] || { echo "Purge cancelled."; return 0; }
    for docker_id in "${purge_ids[@]}"; do
        if docker rm "$docker_id" >/dev/null 2>&1; then removed=$((removed + 1)); fi
    done
    echo "Removed $removed stopped container(s). Locked containers skipped: $locked."
}

docker_start_all_stopped() {
    local docker_line docker_id docker_name docker_status confirmation started=0 failed=0
    local -a docker_lines target_ids target_names
    mapfile -t docker_lines < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}' 2>/dev/null)
    target_ids=(); target_names=()
    for docker_line in "${docker_lines[@]}"; do
        IFS=$'\t' read -r docker_id docker_name docker_status <<< "$docker_line"
        [[ "$docker_status" == Up* ]] && continue
        target_ids+=("$docker_id"); target_names+=("$docker_name")
    done
    if [ "${#target_ids[@]}" -eq 0 ]; then
        echo
        echo "All Docker containers are already running."
        return 0
    fi
    echo
    echo "The following stopped containers will be started:"
    printf '  %s\n' "${target_names[@]}"
    read -r -e -p "Type START ALL to continue: " confirmation
    [ "$confirmation" = "START ALL" ] || { echo "Start all cancelled."; return 0; }
    for docker_id in "${target_ids[@]}"; do
        docker_name="$(docker inspect --format '{{.Name}}' "$docker_id" 2>/dev/null | sed 's#^/##')"
        if docker start "$docker_id" >/dev/null 2>&1; then
            echo "  ✅ Started: ${docker_name:-$docker_id}"
            started=$((started + 1))
        else
            echo "  ❌ Could not start: ${docker_name:-$docker_id}"
            failed=$((failed + 1))
        fi
    done
    echo "Started $started container(s); $failed failed."
    read -r -e -p "Press Enter to return to Docker container management. " _
}

docker_stop_all_running() {
    local docker_line docker_id docker_name docker_status confirmation stopped=0 failed=0
    local -a docker_lines target_ids target_names
    mapfile -t docker_lines < <(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}' 2>/dev/null)
    target_ids=(); target_names=()
    for docker_line in "${docker_lines[@]}"; do
        IFS=$'\t' read -r docker_id docker_name docker_status <<< "$docker_line"
        target_ids+=("$docker_id"); target_names+=("$docker_name")
    done
    if [ "${#target_ids[@]}" -eq 0 ]; then
        echo
        echo "No Docker containers are running."
        return 0
    fi
    echo
    echo "WARNING: This stops these running containers and locks them:"
    printf '  %s\n' "${target_names[@]}"
    read -r -e -p "Type STOP ALL to continue: " confirmation
    [ "$confirmation" = "STOP ALL" ] || { echo "Stop all cancelled."; return 0; }
    for docker_id in "${target_ids[@]}"; do
        docker_name="$(docker inspect --format '{{.Name}}' "$docker_id" 2>/dev/null | sed 's#^/##')"
        if docker stop "$docker_id" >/dev/null 2>&1; then
            docker_set_lock_state "$docker_id" locked || true
            echo "  ✅ Stopped and locked: ${docker_name:-$docker_id}"
            stopped=$((stopped + 1))
        else
            echo "  ❌ Could not stop: ${docker_name:-$docker_id}"
            failed=$((failed + 1))
        fi
    done
    echo "Stopped and locked $stopped container(s); $failed failed."
    read -r -e -p "Press Enter to return to Docker container management. " _
}

docker_purge_container_resources() {
    local docker_id="$1" docker_name="$2" docker_image docker_mount docker_type docker_volume docker_destination confirmation docker_writable_bytes docker_image_bytes docker_volume_mountpoint docker_volume_bytes index removed_estimate=0
    local -a docker_mounts docker_volumes docker_volume_sizes docker_bind_destinations purge_receipt
    docker_image="$(docker inspect --format '{{.Config.Image}}' "$docker_id" 2>/dev/null || true)"
    mapfile -t docker_mounts < <(docker inspect --format '{{range .Mounts}}{{.Type}}\t{{.Name}}\t{{.Destination}}{{"\n"}}{{end}}' "$docker_id" 2>/dev/null)
    docker_volumes=(); docker_volume_sizes=(); docker_bind_destinations=(); purge_receipt=()
    echo
    echo "⚠️  PURGE IS PERMANENT — GONE IS GONE"
    echo "This permanently removes the selected container and its unused Docker-managed resources."
    echo "This cannot be undone. Approach with caution."
    printf '%*s\n' 114 '' | tr ' ' '='
    echo "  Container: $docker_name"
    echo "  Image: ${docker_image:-unknown} (only if no other container uses it)"
    for docker_mount in "${docker_mounts[@]}"; do
        IFS=$'\t' read -r docker_type docker_volume docker_destination <<< "$docker_mount"
        if [ "$docker_type" = "volume" ] && [ -n "$docker_volume" ]; then
            docker_volumes+=("$docker_volume")
            docker_volume_mountpoint="$(docker volume inspect --format '{{.Mountpoint}}' "$docker_volume" 2>/dev/null || true)"
            docker_volume_bytes=""
            if [ -n "$docker_volume_mountpoint" ] && [ -r "$docker_volume_mountpoint" ]; then
                docker_volume_bytes="$(du -sk -- "$docker_volume_mountpoint" 2>/dev/null | awk 'NR==1 {printf "%.0f", $1 * 1024}')"
            fi
            docker_volume_sizes+=("$docker_volume_bytes")
            echo "  Named volume: $docker_volume"
        elif [ "$docker_type" = "bind" ]; then
            docker_bind_destinations+=("$docker_destination")
            echo "  Preserved bind mount: $docker_destination"
        fi
    done
    printf '%*s\n' 114 '' | tr ' ' '='
    echo "⚠️  Bind-mounted host folders will not be deleted by Walker, but purging this container"
    echo "    may affect the application’s access to those folders or leave their data orphaned."
    echo
    read -r -e -p "Type PURGE $docker_name to permanently continue: " confirmation
    [ "$confirmation" = "PURGE $docker_name" ] || { echo "Purge cancelled."; return 0; }
    docker_writable_bytes="$(docker inspect --size --format '{{.SizeRw}}' "$docker_id" 2>/dev/null || true)"
    [[ "$docker_writable_bytes" =~ ^[0-9]+$ ]] || docker_writable_bytes=0
    docker_image_bytes="$(docker image inspect --format '{{.Size}}' "$docker_image" 2>/dev/null || true)"
    [[ "$docker_image_bytes" =~ ^[0-9]+$ ]] || docker_image_bytes=0
    if ! docker rm "$docker_id" >/dev/null 2>&1; then
        echo "❌ Could not remove container: $docker_name"
        return 1
    fi
    purge_receipt+=("  Removed container: $docker_name (writable layer: $(human_bytes "$docker_writable_bytes"))")
    removed_estimate=$((removed_estimate + docker_writable_bytes))
    for index in "${!docker_volumes[@]}"; do
        docker_volume="${docker_volumes[$index]}"
        docker_volume_bytes="${docker_volume_sizes[$index]}"
        if [ -z "$(docker ps -aq --filter "volume=$docker_volume" 2>/dev/null)" ]; then
            if docker volume rm "$docker_volume" >/dev/null 2>&1; then
                if [[ "$docker_volume_bytes" =~ ^[0-9]+$ ]]; then
                    purge_receipt+=("  Removed named volume: $docker_volume ($(human_bytes "$docker_volume_bytes"))")
                    removed_estimate=$((removed_estimate + docker_volume_bytes))
                else
                    purge_receipt+=("  Removed named volume: $docker_volume (size unavailable)")
                fi
            else
                purge_receipt+=("  ⚠️ Could not remove named volume: $docker_volume")
            fi
        else
            purge_receipt+=("  Preserved shared named volume: $docker_volume")
        fi
    done
    if [ -n "$docker_image" ] && [ -z "$(docker ps -aq --filter "ancestor=$docker_image" 2>/dev/null)" ]; then
        if docker image rm "$docker_image" >/dev/null 2>&1; then
            purge_receipt+=("  Removed image: $docker_image ($(human_bytes "$docker_image_bytes"))")
            removed_estimate=$((removed_estimate + docker_image_bytes))
        else
            purge_receipt+=("  ⚠️ Could not remove image: $docker_image")
        fi
    else
        purge_receipt+=("  Preserved image because another container uses it: $docker_image")
    fi
    for docker_destination in "${docker_bind_destinations[@]}"; do
        purge_receipt+=("  Preserved bind mount: $docker_destination (host data unchanged)")
    done
    echo
    printf '%*s\n' 114 '' | tr ' ' '='
    echo "Purge complete: $docker_name"
    printf '%s\n' "${purge_receipt[@]}"
    printf '%*s\n' 114 '' | tr ' ' '='
    echo "Estimated Docker storage released: $(human_bytes "$removed_estimate")"
    echo "Docker Desktop virtual-disk capacity may not shrink immediately; freed space becomes reusable by Docker."
    read -r -e -p "Press Enter to return to Docker container management. " _
}

docker_container_management_menu() {
    local docker_choice docker_line docker_id docker_id_display docker_name docker_status docker_image docker_size docker_state docker_runs_as confirmation management_footer_left management_footer_right docker_notice
    local -a docker_lines
    while true; do
        if [ -n "$docker_notice" ]; then
            echo "  $docker_notice"
            echo
            docker_notice=""
        fi
        mapfile -t docker_lines < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}' 2>/dev/null)
        echo
        printf '%*s\n' 120 '' | tr ' ' '='
        echo "Wombat Walker — Docker container management"
        echo "Stopped containers are locked by default. Unlock one before removing it."
        echo "Removing a container does not remove its images or named volumes."
        printf '%*s\n' 120 '' | tr ' ' '='
        if [ "${#docker_lines[@]}" -eq 0 ]; then
            echo "  No Docker containers were found."
            return 0
        fi
        printf "  %-5s%-13s%-25s%-17s%-34s%-16s%-12s\n" "No." "ID" "Container" "Status" "Image" "Runs as" "Safety"
        docker_choice=1
        for docker_line in "${docker_lines[@]}"; do
            IFS=$'\t' read -r docker_id docker_name docker_status docker_image docker_size <<< "$docker_line"
            docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
            docker_runs_as="$(docker inspect --format '{{.Config.User}}' "$docker_id" 2>/dev/null || true)"
            [ -n "$docker_runs_as" ] || docker_runs_as="image default"
            if [ "$docker_state" = "locked" ]; then
                docker_runs_as=" $docker_runs_as"
                docker_state=" $docker_state"
            fi
            docker_id_display="${docker_id:0:12}"
            [ "${#docker_name}" -le 24 ] || docker_name="${docker_name:0:21}..."
            [ "${#docker_status}" -le 16 ] || docker_status="${docker_status:0:13}..."
            [ "${#docker_image}" -le 33 ] || docker_image="${docker_image:0:30}..."
            [ "${#docker_runs_as}" -le 15 ] || docker_runs_as="${docker_runs_as:0:12}..."
            printf "  %-5s%-13s%-25s%-17s%-34s%-16s%-12s\n" "[$docker_choice]" "$docker_id_display" "$docker_name" "$docker_status" "$docker_image" "$docker_runs_as" "$docker_state"
            docker_choice=$((docker_choice + 1))
        done
        printf '%*s\n' 120 '' | tr ' ' '='
        management_footer_left="  [number] select to manage a container"
        management_footer_right="[q] Return to Docker list"
        echo "  [a] Start all stopped containers    [z] Stop all running containers (locks them)"
        echo
        printf "%-*s%s\n" $((119 - ${#management_footer_right})) "$management_footer_left" "$management_footer_right"
        read -r -e -p "> " docker_choice
        case "$docker_choice" in
            q|Q|"") return 0 ;;
            a|A) docker_start_all_stopped; continue ;;
            z|Z) docker_stop_all_running; continue ;;
        esac
        if ! [[ "$docker_choice" =~ ^[0-9]+$ ]] || [ "$docker_choice" -lt 1 ] || [ "$docker_choice" -gt "${#docker_lines[@]}" ]; then
            echo "❌ Enter a listed container number or q."
            continue
        fi
        IFS=$'\t' read -r docker_id docker_name docker_status docker_image docker_size <<< "${docker_lines[$((docker_choice - 1))]}"
        docker_id_display="${docker_id:0:12}"
        [ "${#docker_status}" -le 23 ] || docker_status="${docker_status:0:20}..."
        [ "${#docker_image}" -le 28 ] || docker_image="${docker_image:0:25}..."
        while true; do
            docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
            echo
            printf '%*s\n' 114 '' | tr ' ' '='
            echo "Container:  $docker_name"
            printf "Id: %-12s    Status: %-17s  Image: %-28s Safety Status: %s\n" "$docker_id_display" "$docker_status" "$docker_image" "$docker_state"
            printf '%*s\n' 114 '' | tr ' ' '='
            if [ -n "$docker_notice" ]; then
                echo "  $docker_notice"
                echo
                docker_notice=""
            fi
            echo
            echo "  [1] Start container"
            echo "  [2] Stop container"
            echo "  [3] Remove container"
            if [ "$docker_state" = "locked" ]; then
            echo "  [4] Unlock container"
            else
                echo "  [4] Lock container"
            fi
            echo "  [5] View mounts and persistent data"
            echo "  [6] PURGE EVERYTHING for this container (permanent)"
            echo "  [7] Bulk remove stopped containers"
            echo
            management_footer_left="  [number] select to manage"
            management_footer_right="[b] Back to container list"
            printf "%-*s%s\n" $((114 - ${#management_footer_right})) "$management_footer_left" "$management_footer_right"
            read -r -e -p "> " confirmation
            case "$confirmation" in
                b|B|q|Q|"") break ;;
                1)
                    if [[ "$docker_status" == Up* ]]; then
                        docker_notice="ℹ️ Container already running: $docker_name"
                    elif docker start "$docker_id" >/dev/null 2>&1; then
                        docker_status="Up"; docker_notice="✅ Container started: $docker_name"
                    else
                        docker_notice="❌ Could not start $docker_name."
                    fi
                    ;;
                2)
                    if [[ "$docker_status" != Up* ]]; then
                        docker_set_lock_state "$docker_id" locked || true
                        docker_notice="ℹ️ Container already stopped and locked: $docker_name"
                    elif docker stop "$docker_id" >/dev/null 2>&1; then
                        docker_status="Exited"; docker_set_lock_state "$docker_id" locked || true; docker_notice="✅ Container stopped and locked: $docker_name"
                    else
                        docker_notice="❌ Could not stop $docker_name."
                    fi
                    ;;
                3)
                    if [[ "$docker_status" == Up* ]]; then
                        docker_notice="❌ This container is running. Stop it first before removing it."
                    else
                        docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
                        if [ "$docker_state" = "locked" ]; then
                        docker_notice="❌ Container is locked. Unlock it before removal."
                        else
                            echo
                            echo "This removes the container only. Its images and named volumes remain."
                            read -r -e -p "Type the container name to confirm removal ($docker_name): " confirmation
                            if [ "$confirmation" = "$docker_name" ] && docker rm "$docker_id" >/dev/null 2>&1; then
                                docker_notice="✅ Container removed: $docker_name"
                                break
                            else
                                docker_notice="❌ Removal cancelled or failed."
                            fi
                        fi
                    fi
                    ;;
                4)
                    docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
                    if [[ "$docker_status" == Up* ]]; then
                        docker_notice="❌ Running containers remain locked. Stop the container before unlocking it."
                    elif [ "$docker_state" = "locked" ]; then
                        read -r -e -p "Type the container name to unlock ($docker_name): " confirmation
                        if [ "$confirmation" = "$docker_name" ] && docker_set_lock_state "$docker_id" unlocked; then docker_notice="✅ Container unlocked: $docker_name"; else docker_notice="❌ Unlock cancelled."; fi
                    else
                        if docker_set_lock_state "$docker_id" locked; then docker_notice="✅ Container locked: $docker_name"; else docker_notice="❌ Could not lock container: $docker_name"; fi
                    fi
                    ;;
                5) docker_show_mounts "$docker_id" ;;
                6)
                    if [[ "$docker_status" == Up* ]]; then
                        docker_notice="❌ This container is running. Stop it first before purging it."
                    else
                        docker_state="$(docker_lock_state "$docker_id" "$docker_status")"
                        if [ "$docker_state" = "locked" ]; then
                        echo "❌ Container is locked. Unlock it before purging."
                        else
                            docker_purge_container_resources "$docker_id" "$docker_name" && break
                        fi
                    fi
                    ;;
                7) docker_purge_unlocked_stopped; break ;;
                *) echo "❌ Choose 1, 2, 3, 4, 5, 6, 7, b, or q." ;;
            esac
        done
    done
}

docker_workspace() {
    local docker_choice docker_container docker_name docker_status docker_image docker_size docker_line docker_writable docker_virtual docker_persistent docker_key docker_sort_choice docker_size_bytes docker_container_count docker_running_count docker_exited_count docker_locked_count docker_id_display docker_progress_total docker_progress_completed docker_progress_started docker_progress_elapsed docker_progress_remaining docker_persistent_value
    local -a docker_lines docker_ids docker_names docker_records
    declare -A docker_persistent_sizes=()
    if ! docker info >/dev/null 2>&1; then
        echo "❌ Walker cannot access Docker."
        echo "  Add this user to the docker group, start Docker, then open Walker again."
        return 0
    fi
    echo "Refreshing Walker's private Docker inventory..."
    python3 "$SCRIPT_DIR/wombat-walker-db.py" docker-inventory "$WALKER_DATABASE" || {
        echo "❌ Walker could not save the Docker inventory; live browsing remains available."
    }
    if [ -z "${DOCKER_STORAGE_DISPLAY:-}" ]; then
        echo "Calculating Docker storage (images, containers, volumes, and build cache)..."
        calculate_docker_storage
    fi
    while true; do
        mapfile -t docker_lines < <(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Size}}' 2>/dev/null)
        docker_ids=(); docker_names=()
        docker_records=()
        docker_container_count="${#docker_lines[@]}"; docker_running_count=0; docker_exited_count=0; docker_locked_count=0
        for docker_line in "${docker_lines[@]}"; do
            IFS=$'\t' read -r docker_container docker_name docker_status docker_image docker_size <<< "$docker_line"
            if [[ "$docker_status" == Up* ]]; then docker_running_count=$((docker_running_count + 1)); else docker_exited_count=$((docker_exited_count + 1)); fi
            [ "$(docker_lock_state "$docker_container" "$docker_status")" = "locked" ] && docker_locked_count=$((docker_locked_count + 1))
            docker_writable="$docker_size"; docker_virtual="-"
            if [[ "$docker_size" =~ ^(.+)[[:space:]]+\(virtual[[:space:]]+(.+)\)$ ]]; then
                docker_writable="${BASH_REMATCH[1]}"; docker_virtual="${BASH_REMATCH[2]}"
            fi
            case "$DOCKER_SORT_ORDER" in
                status) docker_key="$docker_status" ;;
                writable)
                    docker_size_bytes="$(docker_size_to_bytes "$docker_writable")"
                    [[ "$docker_size_bytes" =~ ^[0-9]+$ ]] || docker_size_bytes=0
                    docker_key="$(printf '%020d' "$docker_size_bytes")"
                    ;;
                virtual)
                    docker_size_bytes="$(docker_size_to_bytes "$docker_virtual")"
                    [[ "$docker_size_bytes" =~ ^[0-9]+$ ]] || docker_size_bytes=0
                    docker_key="$(printf '%020d' "$docker_size_bytes")"
                    ;;
                persistent)
                    docker_size_bytes="${docker_persistent_sizes[$docker_container]:-0}"
                    [[ "$docker_size_bytes" =~ ^[0-9]+$ ]] || docker_size_bytes=0
                    docker_key="$(printf '%020d' "$docker_size_bytes")"
                    ;;
                *) docker_key="$docker_name" ;;
            esac
            docker_records+=("$docker_key"$'\t'"$docker_line")
        done
        if [ "${#docker_records[@]}" -gt 0 ]; then
            if [ "$DOCKER_SORT_ORDER" = "writable" ] || [ "$DOCKER_SORT_ORDER" = "virtual" ] || [ "$DOCKER_SORT_ORDER" = "persistent" ]; then
                mapfile -t docker_lines < <(printf '%s\n' "${docker_records[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr | cut -f2-)
            else
                mapfile -t docker_lines < <(printf '%s\n' "${docker_records[@]}" | LC_ALL=C sort -t $'\t' -k1,1f | cut -f2-)
            fi
        fi
        echo
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "Wombat Walker — Docker filesystem explorer"
        echo "Docker Engine: running    Containers: $docker_container_count    Running: $docker_running_count    Exited: $docker_exited_count    Locked :$docker_locked_count"
        echo "Docker Engine storage: Images $DOCKER_IMAGES_DISPLAY    Layers $DOCKER_CONTAINER_LAYERS_DISPLAY    Volumes $DOCKER_VOLUMES_DISPLAY    Cache $DOCKER_BUILD_CACHE_DISPLAY"
        if docker_desktop_disk_summary; then
            echo
            printf "%-74s  Order: %s\n" "Unused virtual capacity does not currently consume host disk space." "$DOCKER_SORT_ORDER"
        else
            printf "%-74s  Order: %s\n" "" "$DOCKER_SORT_ORDER"
        fi
        printf '%*s\n' 114 '' | tr ' ' '='
        printf "  %-5s%-13s%-20s%-17s%-26s %5s%10s %12s\n" "No." "ID" "Container" "Status" "Image" "Layer" "Size" "Persistent"
        if [ "${#docker_lines[@]}" -eq 0 ]; then
            echo "  No Docker containers were found."
        fi
        docker_choice=1
        for docker_line in "${docker_lines[@]}"; do
            IFS=$'\t' read -r docker_container docker_name docker_status docker_image docker_size <<< "$docker_line"
            docker_ids+=("$docker_container"); docker_names+=("$docker_name")
            docker_writable="$docker_size"; docker_virtual="-"
            if [[ "$docker_size" =~ ^(.+)[[:space:]]+\(virtual[[:space:]]+(.+)\)$ ]]; then
                docker_writable="${BASH_REMATCH[1]}"; docker_virtual="${BASH_REMATCH[2]}"
            fi
            docker_persistent="${docker_persistent_sizes[$docker_container]:-not measured}"
            [[ "$docker_persistent" =~ ^[0-9]+$ ]] && docker_persistent="$(human_bytes "$docker_persistent")"
            [ "$docker_persistent" = "not measured" ] && docker_persistent="  not measured"
            docker_id_display="${docker_container:0:12}"
            [ "${#docker_name}" -le 19 ] || docker_name="${docker_name:0:16}..."
            [ "${#docker_status}" -le 16 ] || docker_status="${docker_status:0:13}..."
            [ "${#docker_image}" -le 25 ] || docker_image="${docker_image:0:22}..."
            printf "  %-5s%-13s%-20s%-17s%-26s %5s%10s %12s\n" "[$docker_choice]" "$docker_id_display" "$docker_name" "$docker_status" "$docker_image" "$docker_writable" "$docker_virtual" "$docker_persistent"
            docker_choice=$((docker_choice + 1))
        done
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "Saved Docker scans make filename/path search fast. They contain metadata only and never change containers or data."
        echo "Containers are isolated applications. Select one to browse its live files or inspect where its data is stored."
        echo
        printf "  %-34s%-34s%-34s%s\n" "[a] Scan all running containers" "[r] Refresh container list" "[k] Manage Docker Containers" "[?] help"
        printf "  %-34s%-34s%-34s%s\n" "[o] Change display order" "[s] Search saved Docker scans" "[d] Calculate persistent data" "[q] Walker"
        read -r -e -p "> " docker_choice
        case "$docker_choice" in
            q|Q|"") return 0 ;;
            h|H|\?) docker_help_screen; read -r -e -p "Press Enter to return to Docker containers. " _ ;;
            k|K) docker_container_management_menu ;;
            r|R) ;;
            d|D)
                docker_progress_total=0
                for docker_line in "${docker_lines[@]}"; do
                    IFS=$'\t' read -r docker_container docker_name docker_status docker_image docker_size <<< "$docker_line"
                    [[ "$docker_status" == Up* ]] && docker_progress_total=$((docker_progress_total + 1))
                done
                if [ "$docker_progress_total" -eq 0 ]; then
                    echo "No running containers have writable named-volume or bind-mount data to measure."
                    continue
                fi
                docker_progress_completed=0
                docker_progress_started="$(date +%s)"
                echo "Calculating writable named-volume and bind-mount data — 0 of $docker_progress_total running containers measured"
                for docker_line in "${docker_lines[@]}"; do
                    IFS=$'\t' read -r docker_container docker_name docker_status docker_image docker_size <<< "$docker_line"
                    [[ "$docker_status" == Up* ]] || continue
                    docker_progress_completed=$((docker_progress_completed + 1))
                    echo "  [$docker_progress_completed/$docker_progress_total] Measuring $docker_name..."
                    docker_persistent_value="$(docker_persistent_data_bytes "$docker_container")"
                    docker_persistent_sizes["$docker_container"]="$docker_persistent_value"
                    docker_progress_elapsed=$(( $(date +%s) - docker_progress_started ))
                    if [ "$docker_progress_completed" -lt "$docker_progress_total" ]; then
                        docker_progress_remaining=$(( docker_progress_elapsed * (docker_progress_total - docker_progress_completed) / docker_progress_completed ))
                        echo "      Done: $(human_bytes "$docker_persistent_value")    ${docker_progress_elapsed}s elapsed    Approx. ${docker_progress_remaining}s remaining"
                    else
                        echo "      Done: $(human_bytes "$docker_persistent_value")    ${docker_progress_elapsed}s elapsed    Measurement complete"
                    fi
                done
                ;;
            a|A) docker_scan_all_running ;;
            s|S) docker_search_menu ;;
            o|O)
                printf "  %-34s%-24s%s\n" "[1] Alphabetical by container name" "[2] Status" "[3] Layer size"
                printf "  %-34s%s\n" "[4] Image/virtual size" "[5] Persistent data"
                read -r -e -p "> " docker_sort_choice
                case "$docker_sort_choice" in
                    1) DOCKER_SORT_ORDER="alphabetical" ;;
                    2) DOCKER_SORT_ORDER="status" ;;
                    3) DOCKER_SORT_ORDER="writable" ;;
                    4) DOCKER_SORT_ORDER="virtual" ;;
                    5) DOCKER_SORT_ORDER="persistent" ;;
                    *) echo "❌ Enter 1, 2, 3, 4, or 5." ;;
                esac
                if [[ "$docker_sort_choice" =~ ^[1-5]$ ]]; then
                    if save_preference "DOCKER_SORT_ORDER" "$DOCKER_SORT_ORDER"; then
                        echo "Docker display order saved: $DOCKER_SORT_ORDER"
                    fi
                fi
                ;;
            *)
                if [[ "$docker_choice" =~ ^[0-9]+$ ]] && [ "$docker_choice" -ge 1 ] && [ "$docker_choice" -le "${#docker_ids[@]}" ]; then
                    browse_docker_container "${docker_ids[$((docker_choice - 1))]}" "${docker_names[$((docker_choice - 1))]}"
                else
                    echo "❌ Enter a listed container number, a, o, s, h, r, or q."
                fi
                ;;
        esac
    done
}

bulk_parse_selection() {
    local selection="$1" maximum="$2" compact part range_start range_end index
    local -a parts
    declare -A selected_once=()
    BULK_SELECTED_INDICES=()
    compact="${selection//[[:space:]]/}"
    [[ "$compact" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?(,[1-9][0-9]*(-[1-9][0-9]*)?)*$ ]] || return 1
    IFS=',' read -r -a parts <<< "$compact"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            range_start="${part%-*}"; range_end="${part#*-}"
        else
            range_start="$part"; range_end="$part"
        fi
        [ "$range_start" -le "$range_end" ] && [ "$range_end" -le "$maximum" ] || return 1
        for ((index=range_start; index<=range_end; index++)); do selected_once[$index]=1; done
    done
    for ((index=1; index<=maximum; index++)); do
        [ -n "${selected_once[$index]:-}" ] && BULK_SELECTED_INDICES+=("$index")
    done
    return 0
}

bulk_move_selected_to_trash() {
    local cleanup_folder="$1" selected_number cleanup_choice candidate candidate_parent confirmation
    local moved_count=0 failed_count=0 moved_allocated=0 failure_names=""
    local -a trash_result
    echo
    echo "This moves ${#BULK_SELECTED_INDICES[@]} selected regular files to Wombat Trash."
    echo "They can be restored inside Walker; this is not permanent deletion."
    read -r -e -p "Type TRASH to move ${#BULK_SELECTED_INDICES[@]} files to Wombat Trash: " confirmation
    if [ "$confirmation" != "TRASH" ]; then
        echo "Move to Trash cancelled; no files were changed."
        return 0
    fi
    for selected_number in "${BULK_SELECTED_INDICES[@]}"; do
        cleanup_choice=$((selected_number - 1))
        candidate="${candidates[$cleanup_choice]}"
        candidate_parent="$(dirname -- "$candidate")"
        # The preview may become stale while the user reads it, so validate the live exact path.
        if [ "$candidate_parent" != "$cleanup_folder" ] || [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
            failed_count=$((failed_count + 1))
            failure_names+="$(basename -- "$candidate"); "
            continue
        fi
        trash_result=()
        mapfile -d '' -t trash_result < <(python3 "$SCRIPT_DIR/wombat-walker-trash.py" move "$WALKER_TRASH_ROOT" "$candidate")
        if [ "${#trash_result[@]}" -eq 6 ]; then
            moved_count=$((moved_count + 1))
            moved_allocated=$((moved_allocated + allocated_sizes[$cleanup_choice]))
            python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-log "$WALKER_DATABASE" trash_move "$candidate" file "${logical_sizes[$cleanup_choice]}" "${allocated_sizes[$cleanup_choice]}" success "Wombat Trash entry ${trash_result[0]}" >/dev/null 2>&1 || true
        else
            failed_count=$((failed_count + 1))
            failure_names+="$(basename -- "$candidate"); "
            python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-log "$WALKER_DATABASE" trash_move "$candidate" file "${logical_sizes[$cleanup_choice]}" "${allocated_sizes[$cleanup_choice]}" failed "Could not move to Wombat Trash" >/dev/null 2>&1 || true
        fi
    done
    if [ "$moved_count" -gt 0 ]; then
        python3 "$SCRIPT_DIR/wombat-walker-db.py" mark-stale "$WALKER_DATABASE" "$cleanup_folder" >/dev/null 2>&1 || true
        notice="Moved $moved_count file(s) ($(human_bytes "$moved_allocated") on disk) to Wombat Trash; disk space is not freed until Trash is emptied."
        if [ "$failed_count" -gt 0 ]; then
            notice+=" $failed_count skipped/failed: ${failure_names% }"
        fi
        notice+=" Saved scan totals are stale; use [v] Update saved scan when ready."
        return 0
    fi
    notice="❌ No files were moved to Wombat Trash. $failed_count file(s) had changed, disappeared, or could not be trashed."
    return 1
}

bulk_cleanup_preview() {
    local cleanup_folder raw_extension extension raw_prefix filename_prefix candidate logical_size allocated_blocks allocated_size modified_epoch modified_display display_name candidate_name
    local total_logical=0 total_allocated=0 selected_logical=0 selected_allocated=0 cleanup_choice selection_mode selection_text selected_number selected_action
    local -a candidates logical_sizes allocated_sizes modified_times
    cleanup_folder="$1"
    if [ "$cleanup_folder" = "/" ]; then
        echo "❌ Bulk cleanup is never available for the filesystem root."
        return 1
    fi
    if [ ! -d "$cleanup_folder" ] || [ ! -w "$cleanup_folder" ] || [ ! -x "$cleanup_folder" ]; then
        echo "❌ You cannot clean this folder with the current user."
        echo "  Walker never uses sudo for deletion or bulk cleanup."
        return 1
    fi
    echo
    echo "Bulk cleanup preview — current folder only"
    echo "Only direct regular files are shown; subfolders and symbolic links are always excluded."
    candidates=(); logical_sizes=(); allocated_sizes=(); modified_times=()
    while IFS= read -r -d '' candidate; do
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        read -r logical_size allocated_blocks modified_epoch < <(stat -c '%s %b %Y' -- "$candidate" 2>/dev/null)
        [[ "$logical_size" =~ ^[0-9]+$ ]] && [[ "$allocated_blocks" =~ ^[0-9]+$ ]] && [[ "$modified_epoch" =~ ^[0-9]+$ ]] || continue
        allocated_size=$((allocated_blocks * 512))
        candidates+=("$candidate")
        logical_sizes+=("$logical_size")
        allocated_sizes+=("$allocated_size")
        modified_times+=("$modified_epoch")
        total_logical=$((total_logical + logical_size))
        total_allocated=$((total_allocated + allocated_size))
    done < <(find -P "$cleanup_folder" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
    echo
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "No direct regular files were found in: $cleanup_folder"
        return 0
    fi
    echo "All direct regular files in: $cleanup_folder"
    printf "  %-5s%-40s %12s  %12s  %-16s\n" "No." "Name" "Logical size" "On disk" "Last updated"
    for ((cleanup_choice=0; cleanup_choice<${#candidates[@]}; cleanup_choice++)); do
        display_name="$(basename "${candidates[$cleanup_choice]}")"
        [ "${#display_name}" -le 40 ] || display_name="${display_name:0:37}..."
        modified_display="$(date -d "@${modified_times[$cleanup_choice]}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
        printf "  %-5s%-40s %12s  %12s  %-16s\n" "[$((cleanup_choice + 1))]" "$display_name" "$(human_bytes "${logical_sizes[$cleanup_choice]}")" "$(human_bytes "${allocated_sizes[$cleanup_choice]}")" "$modified_display"
    done
    echo
    echo "Candidates: ${#candidates[@]} regular files"
    echo "All file data: $(human_bytes "$total_logical") logical | $(human_bytes "$total_allocated") on disk"
    while true; do
        echo
        echo "  [a] Select all previewed files"
        echo "  [n] Select numbered files or ranges (examples: 1,3,7 or 1-9)"
        echo "  [t] Select all files of one exact extension"
        echo "  [s] Select files whose names start with text"
        echo "  [q] Return without changes"
        read -r -e -p "> " selection_mode
        case "$selection_mode" in
            q|Q|"") return 0 ;;
            a|A)
                BULK_SELECTED_INDICES=()
                for ((selected_number=1; selected_number<=${#candidates[@]}; selected_number++)); do BULK_SELECTED_INDICES+=("$selected_number"); done
                ;;
            n|N)
                read -r -e -p "File numbers or ranges: " selection_text
                if ! bulk_parse_selection "$selection_text" "${#candidates[@]}"; then
                    echo "❌ Enter valid preview numbers, for example 1,3,7 or 1-9, 14, 22-25."
                    continue
                fi
                ;;
            t|T)
                read -r -e -p "Extension to select (examples: wav, .wav, *.wav): " raw_extension
                [ -n "$raw_extension" ] || { echo "Extension selection cancelled."; continue; }
                case "$raw_extension" in
                    \*.*) extension="${raw_extension#*.}" ;;
                    .*) extension="${raw_extension#.}" ;;
                    *) extension="$raw_extension" ;;
                esac
                if [[ ! "$extension" =~ ^[[:alnum:]][[:alnum:]._-]*$ ]]; then
                    echo "❌ Enter one exact extension such as wav, .wav, or *.wav."
                    echo "  Broad patterns such as *wav or * are not allowed."
                    continue
                fi
                BULK_SELECTED_INDICES=()
                for ((selected_number=1; selected_number<=${#candidates[@]}; selected_number++)); do
                    candidate_name="$(basename "${candidates[$((selected_number - 1))]}")"
                    [[ "${candidate_name,,}" == *."${extension,,}" ]] && BULK_SELECTED_INDICES+=("$selected_number")
                done
                if [ "${#BULK_SELECTED_INDICES[@]}" -eq 0 ]; then
                    echo "No direct regular .$extension files were found in this folder."
                    continue
                fi
                ;;
            s|S)
                read -r -e -p "Filename prefix to select (literal text): " raw_prefix
                [ -n "$raw_prefix" ] || { echo "Filename-prefix selection cancelled."; continue; }
                if [[ "$raw_prefix" == *"/"* || "$raw_prefix" == *"*"* || "$raw_prefix" == *"?"* || "$raw_prefix" == *"["* || "$raw_prefix" == *"]"* ]]; then
                    echo "❌ Enter plain filename text only; paths and wildcard characters are not allowed."
                    continue
                fi
                filename_prefix="$raw_prefix"
                BULK_SELECTED_INDICES=()
                for ((selected_number=1; selected_number<=${#candidates[@]}; selected_number++)); do
                    candidate_name="$(basename "${candidates[$((selected_number - 1))]}")"
                    [[ "$candidate_name" == "$filename_prefix"* ]] && BULK_SELECTED_INDICES+=("$selected_number")
                done
                if [ "${#BULK_SELECTED_INDICES[@]}" -eq 0 ]; then
                    echo "No direct regular filenames start with: $filename_prefix"
                    continue
                fi
                ;;
            *) echo "❌ Enter a, n, t, s, or q."; continue ;;
        esac
        selected_logical=0; selected_allocated=0
        echo
        echo "Selected files — preview only"
        printf "  %-5s%-40s %12s  %12s  %-16s\n" "No." "Name" "Logical size" "On disk" "Last updated"
        for selected_number in "${BULK_SELECTED_INDICES[@]}"; do
            cleanup_choice=$((selected_number - 1))
            display_name="$(basename "${candidates[$cleanup_choice]}")"
            [ "${#display_name}" -le 40 ] || display_name="${display_name:0:37}..."
            modified_display="$(date -d "@${modified_times[$cleanup_choice]}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
            printf "  %-5s%-40s %12s  %12s  %-16s\n" "[$selected_number]" "$display_name" "$(human_bytes "${logical_sizes[$cleanup_choice]}")" "$(human_bytes "${allocated_sizes[$cleanup_choice]}")" "$modified_display"
            selected_logical=$((selected_logical + logical_sizes[$cleanup_choice]))
            selected_allocated=$((selected_allocated + allocated_sizes[$cleanup_choice]))
        done
        echo
        echo "Selected: ${#BULK_SELECTED_INDICES[@]} files"
        echo "Selected file data: $(human_bytes "$selected_logical") logical | $(human_bytes "$selected_allocated") on disk"
        echo "Preview only: no files have been changed. Permanent deletion is not available yet."
        echo
        echo "  [t] Move these selected files to Wombat Trash (recoverable)"
        echo "  [b] Choose another selection"
        echo "  [q] Return without changes"
        read -r -e -p "> " selected_action
        case "$selected_action" in
            t|T) bulk_move_selected_to_trash "$cleanup_folder"; return $? ;;
            b|B|"") continue ;;
            q|Q) return 0 ;;
            *) echo "❌ Enter t, b, or q." ;;
        esac
    done
}

wombat_trash_manager() {
    local trash_mode="$1"
    local -a trash_fields trash_ids trash_paths trash_types trash_logical trash_allocated trash_dates
    local field_index entry_count entry_index display_path selection action confirmation confirmation_count
    local selected_logical selected_allocated restored_count purged_count failed_count result_index
    local -a trash_result
    while true; do
        trash_fields=(); trash_ids=(); trash_paths=(); trash_types=(); trash_logical=(); trash_allocated=(); trash_dates=()
        mapfile -d '' -t trash_fields < <(python3 "$SCRIPT_DIR/wombat-walker-trash.py" list "$WALKER_TRASH_ROOT")
        for ((field_index=0; field_index<${#trash_fields[@]}; field_index+=6)); do
            [ -n "${trash_fields[$field_index]:-}" ] || continue
            trash_ids+=("${trash_fields[$field_index]}")
            trash_paths+=("${trash_fields[$((field_index + 1))]}")
            trash_types+=("${trash_fields[$((field_index + 2))]}")
            trash_logical+=("${trash_fields[$((field_index + 3))]}")
            trash_allocated+=("${trash_fields[$((field_index + 4))]}")
            trash_dates+=("${trash_fields[$((field_index + 5))]}")
        done
        entry_count="${#trash_ids[@]}"
        echo
        if [ "$trash_mode" = "restore" ]; then
            echo "Wombat Trash — restore files"
            echo "Restore returns selected entries to their original paths; it will never overwrite an existing file."
        else
            echo "Wombat Trash — permanent cleanup"
            echo "Items here were moved by Walker. They still occupy disk space until permanently deleted."
        fi
        if [ "$entry_count" -eq 0 ]; then
            echo "  Wombat Trash is empty."
            read -r -e -p "Press Enter to return to Utilities. " _
            return 0
        fi
        printf "  %-5s%-5s%-38s %12s  %12s  %-16s\n" "No." "Type" "Original path" "Logical" "On disk" "Trashed at"
        for ((entry_index=0; entry_index<entry_count; entry_index++)); do
            display_path="${trash_paths[$entry_index]}"
            [ "${#display_path}" -le 38 ] || display_path="...${display_path: -35}"
            printf "  %-5s%-5s%-38s %12s  %12s  %-16s\n" "[$((entry_index + 1))]" "${trash_types[$entry_index]:0:4}" "$display_path" "$(human_bytes "${trash_logical[$entry_index]}")" "$(human_bytes "${trash_allocated[$entry_index]}")" "${trash_dates[$entry_index]:0:16}"
        done
        echo
        if [ "$trash_mode" = "restore" ]; then
            echo "  [z] Restore numbered entries to their original paths"
            echo "  [q] Return without changes"
        else
            echo "  [d] Permanently delete numbered entries"
            echo "  [a] Permanently delete every shown entry"
            echo "  [q] Return without changes"
        fi
        read -r -e -p "> " action
        case "$action" in
            q|Q|"") return 0 ;;
            a|A)
                [ "$trash_mode" = "purge" ] || { echo "❌ Enter z or q."; continue; }
                BULK_SELECTED_INDICES=()
                for ((entry_index=1; entry_index<=entry_count; entry_index++)); do BULK_SELECTED_INDICES+=("$entry_index"); done
                action="d"
                ;;
            z|Z)
                [ "$trash_mode" = "restore" ] || { echo "❌ Restore is available from [z] Restore files from Wombat Trash."; continue; }
                action="r"
                read -r -e -p "Trash entry numbers or ranges (examples: 1,3,7 or 1-9): " selection
                if ! bulk_parse_selection "$selection" "$entry_count"; then
                    echo "❌ Enter valid Trash entry numbers, for example 1,3,7 or 1-9."
                    continue
                fi
                ;;
            d|D)
                [ "$trash_mode" = "purge" ] || { echo "❌ Enter z or q."; continue; }
                read -r -e -p "Trash entry numbers or ranges (examples: 1,3,7 or 1-9): " selection
                if ! bulk_parse_selection "$selection" "$entry_count"; then
                    echo "❌ Enter valid Trash entry numbers, for example 1,3,7 or 1-9."
                    continue
                fi
                ;;
            *) echo "❌ Enter r, d, a, or q."; continue ;;
        esac
        selected_logical=0; selected_allocated=0
        for entry_index in "${BULK_SELECTED_INDICES[@]}"; do
            result_index=$((entry_index - 1))
            selected_logical=$((selected_logical + trash_logical[$result_index]))
            selected_allocated=$((selected_allocated + trash_allocated[$result_index]))
        done
        echo "Selected: ${#BULK_SELECTED_INDICES[@]} Trash entries — $(human_bytes "$selected_logical") logical | $(human_bytes "$selected_allocated") on disk"
        if [ "$action" = "r" ] || [ "$action" = "R" ]; then
            read -r -e -p "Type RESTORE to return these entries to their original paths: " confirmation
            [ "$confirmation" = "RESTORE" ] || { echo "Restore cancelled; no entries were changed."; continue; }
            restored_count=0; failed_count=0
            for entry_index in "${BULK_SELECTED_INDICES[@]}"; do
                result_index=$((entry_index - 1)); trash_result=()
                mapfile -d '' -t trash_result < <(python3 "$SCRIPT_DIR/wombat-walker-trash.py" restore "$WALKER_TRASH_ROOT" "${trash_ids[$result_index]}")
                if [ "${#trash_result[@]}" -eq 5 ]; then
                    restored_count=$((restored_count + 1))
                    python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-log "$WALKER_DATABASE" restore "${trash_result[1]}" "${trash_result[2]}" "${trash_result[3]}" "${trash_result[4]}" success "Restored from Wombat Trash" >/dev/null 2>&1 || true
                else
                    failed_count=$((failed_count + 1))
                fi
            done
            notice="Restored $restored_count Wombat Trash entr$( [ "$restored_count" -eq 1 ] && echo y || echo ies )."
            [ "$failed_count" -eq 0 ] || notice+=" $failed_count could not be restored."
            continue
        fi
        echo "WARNING: This permanently deletes the selected Wombat Trash entries. They cannot be recovered."
        read -r -e -p "Type DELETE to continue: " confirmation
        [ "$confirmation" = "DELETE" ] || { echo "Permanent deletion cancelled; no entries were changed."; continue; }
        read -r -e -p "Type DELETE ${#BULK_SELECTED_INDICES[@]} to permanently delete these entries: " confirmation_count
        [ "$confirmation_count" = "DELETE ${#BULK_SELECTED_INDICES[@]}" ] || { echo "Permanent deletion cancelled; no entries were changed."; continue; }
        purged_count=0; failed_count=0
        for entry_index in "${BULK_SELECTED_INDICES[@]}"; do
            result_index=$((entry_index - 1)); trash_result=()
            mapfile -d '' -t trash_result < <(python3 "$SCRIPT_DIR/wombat-walker-trash.py" purge "$WALKER_TRASH_ROOT" "${trash_ids[$result_index]}")
            if [ "${#trash_result[@]}" -eq 5 ]; then
                purged_count=$((purged_count + 1))
                python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-log "$WALKER_DATABASE" trash_purge "${trash_result[1]}" "${trash_result[2]}" "${trash_result[3]}" "${trash_result[4]}" success "Permanently deleted from Wombat Trash" >/dev/null 2>&1 || true
            else
                failed_count=$((failed_count + 1))
            fi
        done
        notice="Permanently deleted $purged_count Wombat Trash entr$( [ "$purged_count" -eq 1 ] && echo y || echo ies ); expected disk space freed: $(human_bytes "$selected_allocated")."
        [ "$failed_count" -eq 0 ] || notice+=" $failed_count could not be deleted."
    done
}

walker_management_path_allowed() {
    local checked_path
    checked_path="$(realpath -m -- "$1")"
    case "$checked_path" in
        /etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/var/lib/docker|/var/lib/docker/*)
            echo "❌ Walker file management is blocked for protected system paths: $checked_path"
            echo "  Use [!] Open shell in this folder only when you deliberately need an admin command."
            return 1
            ;;
    esac
    return 0
}

walker_mount_root() {
    command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$1"
}

file_management_menu() {
    local managed_path managed_parent managed_type managed_size management_choice trash_confirmation
    local destination_folder destination_path destination_input destination_name new_name confirmation action_name
    local -a trash_result
    managed_path="$1"
    TRASHED_PATH=""
    FILE_MANAGEMENT_RESULT=""
    FILE_MANAGEMENT_DESTINATION=""
    if [ "$managed_path" = "/" ]; then
        notice="❌ Wombat Walker will not move the filesystem root to Trash."
        return 0
    fi
    if [ ! -e "$managed_path" ] || [ -L "$managed_path" ]; then
        echo "❌ This path no longer exists: $managed_path"
        return 1
    fi
    walker_management_path_allowed "$managed_path" || return 0
    managed_parent="$(dirname "$managed_path")"
    if [ -d "$managed_path" ]; then managed_type="folder"; else managed_type="file"; fi
    managed_size="$(du -sh --apparent-size -x -- "$managed_path" 2>/dev/null | awk '{print $1}')"
    [ -n "$managed_size" ] || managed_size="unavailable"
    while true; do
        echo
        echo "File management"
        echo "Path: $managed_path"
        echo "Type: $managed_type    Logical size: $managed_size"
        echo
        echo "  [1] Copy to another folder"
        echo "  [2] Move to another folder"
        echo "  [3] Rename"
        [ "$managed_type" = "folder" ] && echo "  [4] Create a folder inside this folder"
        echo "  [t] Move to Trash (recoverable)"
        echo "  [q] Return without changes"
        read -r -e -p "> " management_choice
        case "$management_choice" in
            q|Q|"") return 0 ;;
            1|2)
                if [ "$management_choice" = 2 ] && walker_mount_root "$managed_path"; then
                    notice="❌ Walker will not move the root of a mounted filesystem."
                    continue
                fi
                if [ "$management_choice" = 2 ] && { [ ! -w "$managed_parent" ] || [ ! -x "$managed_parent" ]; }; then
                    notice="❌ Move is unavailable: the source folder is not writable. Walker never uses sudo for file management."
                    continue
                fi
                read -r -e -p "Destination path (existing folder or new item path): " destination_folder
                if [[ "$destination_folder" != /* ]] || [ -L "$destination_folder" ]; then
                    echo "❌ Enter an absolute destination path that is not a symbolic link."
                    continue
                fi
                if [ -d "$destination_folder" ]; then
                    destination_folder="$(realpath "$destination_folder")"
                    destination_path="$destination_folder/${managed_path##*/}"
                elif [ -e "$destination_folder" ]; then
                    echo "❌ Destination already exists; Walker never overwrites files or folders."
                    continue
                else
                    destination_input="$destination_folder"
                    destination_name="$(basename "$destination_input")"
                    destination_folder="$(dirname "$destination_folder")"
                    if [ ! -d "$destination_folder" ] || [ -L "$destination_folder" ]; then
                        echo "❌ The parent destination folder does not exist or is a symbolic link."
                        continue
                    fi
                    destination_folder="$(realpath "$destination_folder")"
                    destination_path="$destination_folder/$destination_name"
                fi
                walker_management_path_allowed "$destination_folder" || continue
                if [ ! -w "$destination_folder" ] || [ ! -x "$destination_folder" ]; then
                    echo "❌ You cannot write to that destination folder. Walker will not request sudo."
                    continue
                fi
                if [ "$managed_type" = "folder" ] && [[ "$destination_path" = "$managed_path" || "$destination_path" == "$managed_path/"* ]]; then
                    echo "❌ A folder cannot be copied or moved into itself."
                    continue
                fi
                if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
                    echo "❌ Destination already exists; Walker never overwrites files or folders."
                    continue
                fi
                [ "$management_choice" = 1 ] && action_name="copy" || action_name="move"
                echo
                echo "Ready to $action_name this $managed_type"
                echo "  Source:      $managed_path"
                echo "  Destination: $destination_path"
                echo "  Logical size: $managed_size"
                [ "$action_name" = "move" ] && echo "  Note: cross-filesystem moves copy data first, then remove the source."
                read -r -e -p "Type ${action_name^^} to continue: " confirmation
                [ "$confirmation" = "${action_name^^}" ] || { echo "${action_name^} cancelled; nothing changed."; continue; }
                if [ "$action_name" = "copy" ]; then
                    if cp -a -- "$managed_path" "$destination_path"; then
                        FILE_MANAGEMENT_RESULT="copy"; FILE_MANAGEMENT_DESTINATION="$destination_path"
                        echo "Copied to: $destination_path"
                        return 0
                    fi
                    echo "❌ Copy failed; check the destination and available space."
                else
                    mv -- "$managed_path" "$destination_path" && { FILE_MANAGEMENT_RESULT="move"; FILE_MANAGEMENT_DESTINATION="$destination_path"; echo "Moved to: $destination_path"; TRASHED_PATH="$managed_path"; return 0; } || echo "❌ Move failed; check the destination and available space."
                fi
                ;;
            3)
                if walker_mount_root "$managed_path"; then
                    notice="❌ Walker will not rename the root of a mounted filesystem."
                    continue
                fi
                if [ ! -w "$managed_parent" ] || [ ! -x "$managed_parent" ]; then
                    notice="❌ Rename is unavailable: the source folder is not writable. Walker never uses sudo for file management."
                    continue
                fi
                read -r -e -p "New name (not a path): " new_name
                if [ -z "$new_name" ] || [ "$new_name" = "." ] || [ "$new_name" = ".." ] || [[ "$new_name" == */* ]]; then
                    echo "❌ Enter one non-empty name without / characters."
                    continue
                fi
                destination_path="$managed_parent/$new_name"
                if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
                    echo "❌ That name already exists; Walker never overwrites."
                    continue
                fi
                echo "Rename: $managed_path"
                echo "     to: $destination_path"
                read -r -e -p "Type RENAME to continue: " confirmation
                [ "$confirmation" = "RENAME" ] || { echo "Rename cancelled; nothing changed."; continue; }
                mv -- "$managed_path" "$destination_path" && { FILE_MANAGEMENT_RESULT="rename"; FILE_MANAGEMENT_DESTINATION="$destination_path"; echo "Renamed to: $destination_path"; TRASHED_PATH="$managed_path"; return 0; } || echo "❌ Rename failed."
                ;;
            4)
                [ "$managed_type" = "folder" ] || { echo "❌ Create-folder is available only when managing a folder."; continue; }
                read -r -e -p "New folder name (not a path): " new_name
                if [ -z "$new_name" ] || [ "$new_name" = "." ] || [ "$new_name" = ".." ] || [[ "$new_name" == */* ]]; then
                    echo "❌ Enter one non-empty name without / characters."
                    continue
                fi
                destination_path="$managed_path/$new_name"
                if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
                    echo "❌ That name already exists; Walker never overwrites."
                    continue
                fi
                echo "Create folder: $destination_path"
                read -r -e -p "Type CREATE to continue: " confirmation
                [ "$confirmation" = "CREATE" ] || { echo "Create-folder cancelled; nothing changed."; continue; }
                if mkdir -- "$destination_path"; then
                    FILE_MANAGEMENT_RESULT="create"; FILE_MANAGEMENT_DESTINATION="$destination_path"
                    echo "Created folder: $destination_path"
                else
                    echo "❌ Could not create that folder."
                fi
                ;;
            t|T)
                if walker_mount_root "$managed_path"; then
                    notice="❌ Walker will not move the root of a mounted filesystem to Trash."
                    continue
                fi
                if [ ! -w "$managed_parent" ] || [ ! -x "$managed_parent" ]; then
                    notice="❌ Trash is unavailable: the source folder is not writable. Walker never uses sudo for deletion."
                    continue
                fi
                echo "This moves the $managed_type to portable Wombat Trash. It is not a permanent deletion."
                echo "Type TRASH to confirm: $managed_path"
                read -r -e -p "> " trash_confirmation
                [ "$trash_confirmation" = "TRASH" ] || { echo "Move to Trash cancelled."; continue; }
                trash_result=()
                mapfile -d '' -t trash_result < <(python3 "$SCRIPT_DIR/wombat-walker-trash.py" move "$WALKER_TRASH_ROOT" "$managed_path")
                if [ "${#trash_result[@]}" -eq 6 ]; then
                    TRASHED_PATH="$managed_path"
                    FILE_MANAGEMENT_RESULT="trash"
                    python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-log "$WALKER_DATABASE" trash_move "$managed_path" "${trash_result[2]}" "${trash_result[3]}" "${trash_result[4]}" success "Wombat Trash entry ${trash_result[0]}" >/dev/null 2>&1 || true
                    echo "Moved to Wombat Trash: $managed_path"
                    return 0
                fi
                echo "❌ Could not move this path to Wombat Trash."
                return 1
                ;;
            *) echo "❌ Enter 1, 2, 3, 4, t, or q." ;;
        esac
    done
}

load_preferences

file_action_menu() {
    local selected_file action confirmation editor
    selected_file="$1"
    if [ ! -f "$selected_file" ] || [ -L "$selected_file" ]; then
        echo "❌ Cannot edit this selection because it is not a regular non-symlink file."
        echo "  Manage folders, links, devices, and other special files outside Wombat Walker."
        return 1
    fi
    while true; do
        echo
        echo "Selected file: $selected_file"
        echo "  [1] View safely"
        echo "  [2] Edit with preferred editor ($(editor_label "$PREFERRED_EDITOR"))"
        echo "  [3] Choose preferred editor"
        echo "  [4] Edit once with another editor"
        echo "  [5] File management"
        echo "  [q] Return to Walker"
        read -r -e -p "> " action
        editor=""
        case "$action" in
            q|Q|"") return 0 ;;
            1)
                if [ -r "$selected_file" ]; then
                    if [ -x /usr/bin/less ]; then /usr/bin/less -- "$selected_file"; else echo "❌ /usr/bin/less is not installed."; fi
                elif [ "$PRIVILEGED_MODE" = "on" ]; then
                    sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" view-file "$selected_file"
                else
                    echo "❌ Protected viewing is unavailable in this user-only Walker install."
                fi
                continue
                ;;
            2) editor="$(editor_path "$PREFERRED_EDITOR")" ;;
            3) choose_preferred_editor; continue ;;
            4)
                choose_one_off_editor
                [ -n "${ONE_OFF_EDITOR:-}" ] || continue
                editor="$(editor_path "$ONE_OFF_EDITOR")"
                ;;
            5) file_management_menu "$selected_file" || true; return 0 ;;
            *) echo "❌ Enter 1, 2, 3, 4, 5, or q."; continue ;;
        esac
        [ -n "${editor:-}" ] || { [ "$action" = 1 ] || echo "❌ That editor is not installed."; continue; }
        if [ -r "$selected_file" ] && [ -w "$selected_file" ]; then
            echo "Opening with: $editor"
            "$editor" -- "$selected_file"
        elif [ "$PRIVILEGED_MODE" = "on" ]; then
            echo "⚠️  Warning: you are about to modify a protected system file."
            echo "File: $selected_file"
            echo "Type EDIT to confirm before sudo access is requested."
            read -r -e -p "> " confirmation
            [ "$confirmation" = "EDIT" ] || { echo "Edit cancelled."; continue; }
            echo "Requesting sudoedit for this protected file..."
            SUDO_EDITOR="$editor" sudoedit -- "$selected_file"
        else
            echo "❌ Protected editing is unavailable in this user-only Walker install."
        fi
        echo "Returned to Wombat Walker after editor closed."
    done
}

disk_health_history() {
    local history_choice snapshot_id
    local -a history_fields
    while true; do
        history_fields=()
        mapfile -d '' -t history_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" disk-health-history "$WALKER_DATABASE" 2>/dev/null || true)
        echo
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "Saved NVMe disk health history"
        echo "Each check is saved so you can compare a drive before and after moving it."
        printf '%*s\n' 114 '' | tr ' ' '='
        if [ "${#history_fields[@]}" -eq 0 ]; then
            echo "No saved NVMe health checks yet. Run a read-only health check first."
            read -r -e -p "Press Enter to return to the NVMe disk list. " _
            return 0
        fi
        echo "  No.  Captured                         Device         Temperature  Endurance  Hours    Errors  Warning"
        for ((history_choice=0; history_choice<${#history_fields[@]}; history_choice+=10)); do
            printf '  [%d]  %-31s %-14s %-12s %-10s %-8s %-7s %s\n' \
                "$((history_choice / 10 + 1))" "${history_fields[$((history_choice + 1))]}" \
                "${history_fields[$((history_choice + 2))]}" "${history_fields[$((history_choice + 5))]}°C" \
                "${history_fields[$((history_choice + 6))]}%" "${history_fields[$((history_choice + 7))]}" \
                "${history_fields[$((history_choice + 8))]}" "${history_fields[$((history_choice + 9))]}"
            echo "       ${history_fields[$((history_choice + 3))]}    Serial: ${history_fields[$((history_choice + 4))]}"
        done
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "  [number] View saved health report    [q] Return to the NVMe disk list"
        read -r -e -p "> " history_choice
        case "$history_choice" in
            q|Q|"") return 0 ;;
        esac
        if ! [[ "$history_choice" =~ ^[0-9]+$ ]] || [ "$history_choice" -lt 1 ] || [ "$history_choice" -gt $(( ${#history_fields[@]} / 10 )) ]; then
            echo "❌ Enter a listed health report number or q."
            continue
        fi
        snapshot_id="${history_fields[$(((history_choice - 1) * 10))]}"
        echo
        python3 "$SCRIPT_DIR/wombat-walker-db.py" disk-health-snapshot "$WALKER_DATABASE" "$snapshot_id" || echo "❌ Could not read that saved health report."
        echo
        read -r -e -p "Press Enter to return to saved health history. " _
    done
}

disk_health_checker() {
    local disk_choice disk_output disk_device disk_size disk_model disk_serial disk_firmware disk_mounts sudo_choice
    local -a disk_fields
    while true; do
        disk_fields=()
        mapfile -d '' -t disk_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" disk-health-drives "$WALKER_DATABASE" 2>/dev/null || true)
        echo
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "NVMe disk health — select a physical drive"
        echo "A health check is read-only. It does not scan files, write to the drive, or start a self-test."
        printf '%*s\n' 114 '' | tr ' ' '='
        if [ "${#disk_fields[@]}" -eq 0 ]; then
            echo "No physical NVMe drives were found. USB enclosures, SATA drives, and pen drives are planned for v2."
            read -r -e -p "Press Enter to return to Mounted Storage. " _
            return 0
        fi
        for ((disk_choice=0; disk_choice<${#disk_fields[@]}; disk_choice+=6)); do
            disk_device="${disk_fields[$disk_choice]}"; disk_size="${disk_fields[$((disk_choice + 1))]}"
            disk_model="${disk_fields[$((disk_choice + 2))]}"; disk_serial="${disk_fields[$((disk_choice + 3))]}"
            disk_firmware="${disk_fields[$((disk_choice + 4))]}"; disk_mounts="${disk_fields[$((disk_choice + 5))]}"
            echo "  [$((disk_choice / 6 + 1))] $disk_device    Internal NVMe    $(human_bytes "$disk_size")"
            echo "      Model: $disk_model    Serial: $disk_serial    Firmware: $disk_firmware"
            echo "      Mounted at: $disk_mounts"
        done
        printf '%*s\n' 114 '' | tr ' ' '='
        echo "  [number] Run read-only health check    [h] View saved health history    [q] Return to Mounted Storage"
        read -r -e -p "> " disk_choice
        case "$disk_choice" in
            q|Q|"") return 0 ;;
            h|H) disk_health_history; continue ;;
        esac
        if ! [[ "$disk_choice" =~ ^[0-9]+$ ]] || [ "$disk_choice" -lt 1 ] || [ "$disk_choice" -gt $(( ${#disk_fields[@]} / 6 )) ]; then
            echo "❌ Enter a listed drive number, h, or q."
            continue
        fi
        disk_device="${disk_fields[$(((disk_choice - 1) * 6))]}"
        echo
        echo "Reading live NVMe health data for $disk_device..."
        if disk_output="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" disk-health "$WALKER_DATABASE" "$disk_device" 2>&1)"; then
            echo "$disk_output"
        else
            echo "$disk_output"
            if [[ "$disk_output" != *"nvme-cli is not installed"* ]]; then
                read -r -e -p "Try the same read-only check with sudo? [y/N] " sudo_choice
                case "$sudo_choice" in
                    y|Y|yes|YES)
                        if sudo -v; then
                            if disk_output="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" disk-health "$WALKER_DATABASE" "$disk_device" sudo 2>&1)"; then
                                echo "$disk_output"
                            else
                                echo "$disk_output"
                            fi
                        else
                            echo "❌ Sudo authentication was cancelled; no disk health check was run."
                        fi
                        ;;
                esac
            fi
        fi
        echo
        read -r -e -p "Press Enter to return to the NVMe disk list. " _
    done
}

mount_storage_menu() {
    local mount_choice
    while true; do
        echo
        python3 "$SCRIPT_DIR/wombat-walker-db.py" list-mounts "$WALKER_DATABASE" || echo "❌ Could not read the system mount table."
        echo "  [f] Disk health checker (NVMe)    [q] Return to Utilities"
        read -r -e -p "> " mount_choice
        case "$mount_choice" in
            f|F) disk_health_checker ;;
            q|Q|"") return 0 ;;
            *) echo "❌ Enter f or q." ;;
        esac
    done
}

search_utilities_menu() {
    local utility_choice
    while true; do
        echo
        echo "Utilities — current folder: $current"
        echo "  [b] Bulk delete files in this folder (Move to Wombat Trash)"
        echo "  [g] Manage current folder (copy, move, rename, Trash)"
        echo "  [t] Permanently delete files from Wombat Trash"
        echo "  [z] Restore files from Wombat Trash"
        echo "  [l] View Wombat Trash audit log"
        echo "  [c] Browse Docker containers and storage"
        echo "  [!] Open shell in this folder"
        echo "  [?] Show Walker help"
        echo "  [q] Return to search results"
        read -r -e -p "> " utility_choice
        case "$utility_choice" in
            b|B) bulk_cleanup_preview "$current" || true ;;
            g|G) file_management_menu "$current" || true ;;
            t|T) wombat_trash_manager purge ;;
            z|Z) wombat_trash_manager restore ;;
            l|L) python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-list "$WALKER_DATABASE" || true; read -r -e -p "Press Enter to return to Utilities. " _ ;;
            c|C) docker_workspace ;;
            '!') (cd "$current" && "${SHELL:-/bin/bash}") ;;
            \?) walker_help_screen; read -r -e -p "Press Enter to return to Utilities. " _ ;;
            q|Q|"") return 0 ;;
            *) notice="❌ Enter b, g, t, z, l, c, !, ?, or q." ;;
        esac
    done
}

if [ -n "$PRIVILEGED_BROWSE" ]; then
    [ "$PRIVILEGED_MODE" = "on" ] || { echo "❌ Protected browsing is unavailable in this user-only Walker install."; exit 1; }
    sudo -v && browse_protected_folder "$PRIVILEGED_BROWSE"
    exit $?
fi

if [ -n "$FILE_ACTION" ]; then
    file_action_menu "$FILE_ACTION"
    exit $?
fi

walk_filesystem() {
    local current child choice manual_path index item_name display_name total_entries page page_size start_index end_index i
    local -a all_entries
    local size_bytes allocated_bytes allocated_blocks size_needed folder_total_bytes visible_folder_total_bytes hidden_folder_total_bytes folder_total_display hidden_folder_total_display modified_display owner_display record sort_choice target metric epoch history_index entry_kind sparse_info total_delta mismatch_threshold
    local cache_current cache_status cache_stale cache_total cache_path cache_size cache_allocated cache_index notice encryption_choice
    local search_words search_result_number cached_path managed_folder
    local disk_size_bytes disk_used_bytes disk_avail_bytes disk_percent disk_physical_display disk_capacity_display disk_available_display
    local -a directories files entries visible_entries sort_records back_history encryption_label_paths encryption_label_scopes encryption_fields
    local -A size_cache size_bytes_cache allocated_bytes_cache on_disk_cache folder_total_cache cached_folder_total_bytes modified_cache owner_cache cached_folder_checked cached_folder_status

    load_cached_sizes() {
        local -a cache_fields
        [ -n "${cached_folder_checked[$current]:-}" ] && return 0
        cached_folder_checked["$current"]=1
        cache_fields=()
        mapfile -d '' -t cache_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" cached-sizes "$WALKER_DATABASE" "$current" little 2>/dev/null)
        [ "${cache_fields[0]:-}" = "META" ] || return 0
        cache_status="${cache_fields[2]}"; cache_stale="${cache_fields[3]}"; cache_total="${cache_fields[4]}"
        [[ "$cache_total" =~ ^[0-9]+$ ]] || return 0
        cached_folder_total_bytes["$current"]="$cache_total"
        cached_folder_status["$current"]="$cache_status"
        if [ "$cache_stale" = "1" ]; then
            # A targeted refresh invalidates the saved root total. Do not
            # present that stale number as the current folder's total;
            # the main loop will calculate a live value instead.
            cached_folder_status["$current"]="Saved scan stale"
        else
            folder_total_cache["$current"]="$(human_bytes "$cache_total")"
        fi
        for ((cache_index=6; cache_index<${#cache_fields[@]}; cache_index+=4)); do
            [ "${cache_fields[$cache_index]}" = "SIZE" ] || continue
            cache_path="${cache_fields[$((cache_index + 1))]}"; cache_size="${cache_fields[$((cache_index + 2))]}"; cache_allocated="${cache_fields[$((cache_index + 3))]}"
            [[ "$cache_size" =~ ^[0-9]+$ ]] && [[ "$cache_allocated" =~ ^[0-9]+$ ]] || continue
            size_bytes_cache["$cache_path"]="$cache_size"
            allocated_bytes_cache["$cache_path"]="$cache_allocated"
            size_cache["$cache_path"]="$(human_bytes "$cache_size")"
            on_disk_cache["$cache_path"]="$(human_bytes "$cache_allocated")"
        done
    }

    load_encryption_labels() {
        encryption_label_paths=(); encryption_label_scopes=(); encryption_fields=()
        mapfile -d '' -t encryption_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" list-encryption "$WALKER_DATABASE" 2>/dev/null)
        for ((cache_index=0; cache_index<${#encryption_fields[@]}; cache_index+=2)); do
            encryption_label_paths+=("${encryption_fields[$cache_index]}")
            encryption_label_scopes+=("${encryption_fields[$((cache_index + 1))]}")
        done
    }

    is_encryption_labelled() {
        local check_path="$1" label_path label_scope
        for ((cache_index=0; cache_index<${#encryption_label_paths[@]}; cache_index++)); do
            label_path="${encryption_label_paths[$cache_index]}"; label_scope="${encryption_label_scopes[$cache_index]}"
            [ "$check_path" = "$label_path" ] && return 0
            if [ "$label_scope" = "1" ]; then
                [ "$label_path" = "/" ] && [[ "$check_path" = /* ]] && return 0
                [[ "$check_path" = "$label_path/"* ]] && return 0
            fi
        done
        return 1
    }

    measure_item() {
        target="$1"
        if [ -z "${size_bytes_cache[$target]:-}" ] || [ -z "${allocated_bytes_cache[$target]:-}" ]; then
            if [ -d "$target" ]; then
                size_bytes="$(du -s -x -B1 -- "$target" 2>/dev/null | awk 'NR == 1 { print $1 }')"
                allocated_bytes="$size_bytes"
            else
                read -r size_bytes allocated_blocks < <(stat -c '%s %b' -- "$target" 2>/dev/null || true)
                allocated_bytes=$(( ${allocated_blocks:-0} * 512 ))
            fi
            [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes="0"
            [[ "$allocated_bytes" =~ ^[0-9]+$ ]] || allocated_bytes="0"
            size_bytes_cache["$target"]="$size_bytes"
            allocated_bytes_cache["$target"]="$allocated_bytes"
            size_cache["$target"]="$(human_bytes "$size_bytes")"
            on_disk_cache["$target"]="$(human_bytes "$allocated_bytes")"
        fi
        BROWSER_SIZE_BYTES="${size_bytes_cache[$target]}"
    }

    modified_time() {
        target="$1"
        if [ -z "${modified_cache[$target]:-}" ]; then
            epoch="$(stat -c '%Y' -- "$target" 2>/dev/null || true)"
            if [[ "$epoch" =~ ^[0-9]+$ ]]; then
                modified_cache["$target"]="$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
                BROWSER_MODIFIED_EPOCH="$epoch"
            else
                modified_cache["$target"]="?"
                BROWSER_MODIFIED_EPOCH=0
            fi
        else
            BROWSER_MODIFIED_EPOCH="$(stat -c '%Y' -- "$target" 2>/dev/null || echo 0)"
        fi
    }

    file_owner() {
        target="$1"
        if [ -z "${owner_cache[$target]:-}" ]; then
            owner_cache["$target"]="$(stat -c '%U:%G' -- "$target" 2>/dev/null || echo unknown)"
        fi
        OWNER_DISPLAY="${owner_cache[$target]}"
    }

    sort_entries() {
        case "$SORT_ORDER" in
            alphabetical)
                mapfile -d '' -t entries < <(printf '%s\0' "${entries[@]}" | LC_ALL=C sort -z)
                ;;
            largest|smallest|updated)
                sort_records=()
                for target in "${entries[@]}"; do
                    if [ "$SORT_ORDER" = "updated" ]; then
                        modified_time "$target"; metric="$BROWSER_MODIFIED_EPOCH"
                    else
                        measure_item "$target"; metric="$BROWSER_SIZE_BYTES"
                    fi
                    sort_records+=("$(printf '%020d\t%s' "$metric" "$target")")
                done
                if [ "$SORT_ORDER" = "smallest" ]; then
                    mapfile -d '' -t sort_records < <(printf '%s\0' "${sort_records[@]}" | sort -z -t $'\t' -k1,1n)
                else
                    mapfile -d '' -t sort_records < <(printf '%s\0' "${sort_records[@]}" | sort -z -t $'\t' -k1,1nr)
                fi
                entries=()
                for record in "${sort_records[@]}"; do entries+=("${record#*$'\t'}"); done
                ;;
        esac
    }

    current="$(realpath "$START_PATH")"
    back_history=()
    load_encryption_labels
    page=0
    page_size="$ITEMS_PER_PAGE"
    while true; do
        if [ -n "${FILE_MANAGEMENT_RESULT:-}" ]; then
            size_cache=(); size_bytes_cache=(); allocated_bytes_cache=(); on_disk_cache=()
            folder_total_cache=(); cached_folder_total_bytes=(); modified_cache=(); cached_folder_checked=(); cached_folder_status=()
            notice="${FILE_MANAGEMENT_RESULT^} completed: ${FILE_MANAGEMENT_DESTINATION:-current folder}. Live listing refreshed."
            FILE_MANAGEMENT_RESULT=""
        fi
        directories=(); files=()
        if [ -r "$current" ] && [ -x "$current" ]; then
            while IFS= read -r -d '' child; do
                item_name="$(basename "$child")"
                [ "$SHOW_HIDDEN" = "on" ] || [[ "$item_name" != .* ]] || continue
                if [ -L "$child" ]; then files+=("$child")
                elif [ -d "$child" ]; then directories+=("$child")
                elif [ -f "$child" ] || [ -L "$child" ]; then files+=("$child")
                fi
            done < <(find -P "$current" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        fi

        entries=("${directories[@]}" "${files[@]}")
        [ "${#entries[@]}" -gt 0 ] && sort_entries
        all_entries=("${entries[@]}")
        total_entries="${#entries[@]}"
        if [ "$total_entries" -eq 0 ]; then page=0
        elif [ $((page * page_size)) -ge "$total_entries" ]; then page=$(((total_entries - 1) / page_size)); fi
        start_index=$((page * page_size)); end_index=$((start_index + page_size))
        [ "$end_index" -gt "$total_entries" ] && end_index="$total_entries"
        visible_entries=()
        for ((i=start_index; i<end_index; i++)); do visible_entries+=("${entries[$i]}"); done
        entries=("${visible_entries[@]}")

        size_needed=false
        if [ "$SHOW_FILE_SIZES" = "on" ]; then
            load_cached_sizes
            for child in "${entries[@]}"; do [ -n "${size_cache[$child]:-}" ] || { size_needed=true; break; }; done
        fi
        if $size_needed || { [ "$SHOW_FILE_SIZES" = "on" ] && [ -z "${folder_total_cache[$current]:-}" ]; }; then
            echo "  Calculating sizes..."
        fi
        if $size_needed; then for child in "${entries[@]}"; do [ -n "${size_cache[$child]:-}" ] || measure_item "$child"; done; fi
        folder_total_display=""; hidden_folder_total_display=""
        if [ "$SHOW_FILE_SIZES" = "on" ]; then
            if [ ! -r "$current" ] || [ ! -x "$current" ]; then
                folder_total_display="unavailable (protected)"
            elif [ -z "${folder_total_cache[$current]:-}" ]; then
                # -xdev makes this a total for the current filesystem only; mounted disks are separate.
                folder_total_bytes="$(find -P "$current" -xdev -type f -printf '%s\n' 2>/dev/null | awk '{ total += $1 } END { printf "%.0f", total }')"
                [[ "$folder_total_bytes" =~ ^[0-9]+$ ]] || folder_total_bytes="0"
                folder_total_cache["$current"]="$(human_bytes "$folder_total_bytes")"
                if [ "$SHOW_HIDDEN" = "off" ]; then
                    visible_folder_total_bytes="$(find -P "$current" -xdev \( -path "$current/.*" -prune \) -o \( -type f -printf '%s\n' \) 2>/dev/null | awk '{ total += $1 } END { printf "%.0f", total }')"
                    [[ "$visible_folder_total_bytes" =~ ^[0-9]+$ ]] || visible_folder_total_bytes="0"
                    hidden_folder_total_bytes=$((folder_total_bytes - visible_folder_total_bytes))
                    [ "$hidden_folder_total_bytes" -lt 0 ] && hidden_folder_total_bytes=0
                    hidden_folder_total_display="$(human_bytes "$hidden_folder_total_bytes")"
                fi
            fi
            [ -n "$folder_total_display" ] || folder_total_display="${folder_total_cache[$current]}"
        fi

        if [ "${cached_folder_status[$current]:-}" = "Saved scan stale" ] \
            && [[ "${cached_folder_total_bytes[$current]:-}" =~ ^[0-9]+$ ]] \
            && [[ "$folder_total_bytes" =~ ^[0-9]+$ ]]; then
            total_delta=$((folder_total_bytes - cached_folder_total_bytes[$current]))
            [ "$total_delta" -lt 0 ] && total_delta=$((-total_delta))
            mismatch_threshold=$((cached_folder_total_bytes[$current] / 100))
            [ "$mismatch_threshold" -lt 1048576 ] && mismatch_threshold=1048576
            if [ "$total_delta" -ge "$mismatch_threshold" ]; then
                notice="${notice:+$notice }Saved scan mismatch: live $folder_total_display vs saved $(human_bytes "${cached_folder_total_bytes[$current]}")."
            fi
        fi

        # df reports unique allocated filesystem blocks. Unlike the logical file-size total above,
        # it does not double-count hard links and is not inflated by sparse files' apparent size.
        read -r disk_size_bytes disk_used_bytes disk_avail_bytes disk_percent < <(
            df -B1 --output=size,used,avail,pcent "$current" 2>/dev/null | tail -n 1
        )
        if [[ "$disk_size_bytes" =~ ^[0-9]+$ ]] && [[ "$disk_used_bytes" =~ ^[0-9]+$ ]] && [[ "$disk_avail_bytes" =~ ^[0-9]+$ ]]; then
            disk_physical_display="$(human_bytes "$disk_used_bytes")"
            disk_capacity_display="$(human_bytes "$disk_size_bytes")"
            disk_available_display="$(human_bytes "$disk_avail_bytes")"
        else
            disk_physical_display="unavailable"; disk_capacity_display="?"; disk_available_display="?"; disk_percent="?"
        fi

        echo
        echo "=================================================================================================="
        echo "Wombat Walker — filesystem explorer"
        echo "Current folder: $current"
        echo "Order: $SORT_ORDER    Items per page: $page_size    Hidden: $SHOW_HIDDEN"
        echo "=================================================================================================="
        if [ ! -r "$current" ] || [ ! -x "$current" ]; then
            echo "  Protected folder: this user cannot inspect its contents."
            echo "  Use --deep-scan current|filesystem --sudo for an explicit protected inventory."
            echo
        fi
        printf "  %-5s%-10s%-32s %12s  %12s  %-14s %-16s\n" "No." "Type" "Name" "Logical size" "On disk" "Owner" "Last updated"
        index=1
        for child in "${entries[@]}"; do
            item_name="$(basename "$child")"; display_name="$item_name"
            if [ -L "$child" ]; then
                entry_kind="sym"; display_name="${display_name} -> $(readlink -- "$child")"
            elif [ -d "$child" ]; then
                entry_kind="dir"
            else
                entry_kind="file"
            fi
            is_encryption_labelled "$child" && entry_kind="$entry_kind enc"
            [ "${#display_name}" -le 32 ] || display_name="${display_name:0:29}..."
            modified_time "$child"; modified_display="${modified_cache[$child]}"; file_owner "$child"; owner_display="$OWNER_DISPLAY"
            sparse_info=""
            if [[ "$entry_kind" == file* ]] && [[ "${size_bytes_cache[$child]:-}" =~ ^[0-9]+$ ]] && [[ "${allocated_bytes_cache[$child]:-}" =~ ^[0-9]+$ ]] \
                && [ "${size_bytes_cache[$child]}" -gt 0 ] && [ "$(( ${allocated_bytes_cache[$child]} * 100 ))" -lt "${size_bytes_cache[$child]}" ]; then
                sparse_info="sparse"
            fi
            printf "  %-5s%-10s%-32s %12s  %12s  %-14s %-16s\n" "[$index]" "$entry_kind" "$display_name" "${size_cache[$child]:-}" "${on_disk_cache[$child]:-}" "$owner_display" "$modified_display"
            index=$((index + 1))
        done
        if [ "$total_entries" -gt "$page_size" ]; then
            echo
            page_controls="[n] Next page    [p] Previous page"
            showing_text="Showing $((start_index + 1))-$end_index of $total_entries items"
            printf "  %-34s%50s\n" "$page_controls" "$showing_text"
        fi
        echo
        if [ -n "$folder_total_display" ]; then
            if [ "${cached_folder_status[$current]:-}" = "Saved scan stale" ]; then
                echo "  Live file data (including hidden): $folder_total_display — saved index stale; [v] refresh"
            elif [ -n "${cached_folder_status[$current]:-}" ]; then
                echo "  Saved file data (including hidden): $folder_total_display (${cached_folder_status[$current]})"
            else
                echo "  Live file data (including hidden): $folder_total_display"
            fi
            if [ -n "$hidden_folder_total_display" ]; then
                echo "  Hidden file data included: $hidden_folder_total_display"
            fi
        fi
        echo
        echo "  Physical disk use (disk space): $disk_physical_display of $disk_capacity_display ($disk_percent used, $disk_available_display free)"
        if [[ "${DOCKER_STORAGE_BYTES:-}" =~ ^[0-9]+$ ]]; then
            docker_percent="$(awk -v docker_bytes="$DOCKER_STORAGE_BYTES" -v disk_bytes="$disk_size_bytes" 'BEGIN { printf "%.0f", (docker_bytes / disk_bytes) * 100 }')"
            echo "  Docker storage (images, containers, volumes, build cache): $DOCKER_STORAGE_DISPLAY (${docker_percent}% of this filesystem)"
        elif [ "${DOCKER_STORAGE_DISPLAY:-}" = "unavailable" ]; then
            echo "  Docker storage: unavailable (Docker could not provide a storage summary)"
        else
            echo "  Docker storage: open [x] Help & utilities, then [c] to calculate and inspect it"
        fi
        echo
        if [ "$PICK_FOLDER" = "on" ]; then
            dot_action="[.] Use this folder and return"
            first_action="$dot_action"
        else
            first_action="[!] Open shell in this folder"
        fi
        printf "  %-31s %-31s %-29s %s\n" "$first_action" "[u] Up [d] Down one folder" "[x] Management Utilities" "[?] Help"
        printf "  %-31s %-31s %-29s %s\n" "[o] Change display order" "[s] Search folders & files" "[g] Manage current folder" "[q] Quit"
        echo
        if [ -n "$notice" ]; then
            echo "  $notice"
            echo
            notice=""
        fi

        read -r -e -p "> " choice
        case "$choice" in
            .)
                if [ "$PICK_FOLDER" = "on" ]; then
                    printf '%s\n' "$current"
                    return 0
                fi
                notice="Current folder: $current"
                ;;
            '!')
                echo "Opening a normal user shell in: $current"
                echo "Type exit to return to Wombat Walker."
                (
                    cd "$current" || exit 1
                    "${SHELL:-/bin/bash}"
                )
                ;;
            g|G)
                file_management_menu "$current" || true
                ;;
            \?)
                walker_help_screen
                read -r -e -p "Press Enter to return to Walker. " _
                ;;
            u|U) [ "$current" = "/" ] || { back_history+=("$current"); current="$(dirname "$current")"; page=0; } ;;
            d|D)
                if [ "${#back_history[@]}" -gt 0 ]; then
                    history_index=$((${#back_history[@]} - 1))
                    current="${back_history[$history_index]}"
                    unset "back_history[$history_index]"
                    page=0
                else
                    notice="❌ There is no previous folder in this Walker session."
                fi
                ;;
            n|N) [ "$end_index" -lt "$total_entries" ] && page=$((page + 1)) || notice="❌ This is the last page." ;;
            p|P) [ "$page" -gt 0 ] && page=$((page - 1)) || notice="❌ This is the first page." ;;
            x|X)
                echo
                if [ "$SHOW_FILE_SIZES" = "on" ]; then
                    display_size_option="[f] Disable file-size calculations"
                else
                    display_size_option="[f] Enable file-size display and cached totals"
                fi
                if [ "$SHOW_HIDDEN" = "on" ]; then
                    display_hidden_option="[h] Hide hidden files"
                else
                    display_hidden_option="[h] Include hidden files"
                fi
                printf "  %-58s%s\n" "Management Utilities" "Display Utilities"
                printf "  %-58s%s\n" "====================" "================="
                printf "  %-58s%s\n" "[r] Reload this folder's live listing" "[i] Items per page (currently: $page_size)"
                printf "  %-58s%s\n" "$display_size_option" "$display_hidden_option"
                printf "  %-58s%s\n" "[e] Encryption label (enc)" "[d] Set saved default display order"
                printf "  %-58s%s\n" "[v] Update saved scan below this folder (may be slow)" "[?] Show Walker help and command-line flags"
                printf "  %-58s%s\n" "[m] Show mounted data filesystems" "[q] Return to Walker"
                printf "  %-58s%s\n" "[c] Browse Docker containers and storage" ""
                printf "  %-58s%s\n" "[!] Open shell in this folder" ""
                echo
                echo "  File cleanup utilities"
                echo "  ======================"
                echo "  [b] Bulk delete files in this folder (Move to Wombat Trash)"
                echo "  [g] Manage current folder (copy, move, rename, Trash)"
                echo "  [t] Permanently delete files from Wombat Trash"
                echo "  [z] Restore files from Wombat Trash"
                echo "  [l] View Wombat Trash audit log"
                read -r -e -p "> " utility_choice
                case "$utility_choice" in
                    r|R)
                        page=0
                        notice="Reloaded the live folder listing. Saved scan metadata was not updated."
                        ;;
                    v|V)
                        read -r -e -p "Refresh only this folder and its descendants? [y/N] " refresh_choice
                        case "$refresh_choice" in
                            y|Y|yes|YES)
                                python3 "$SCRIPT_DIR/wombat-walker-db.py" scan "$WALKER_DATABASE" "$current" little || echo "❌ Refresh failed."
                                size_cache=(); size_bytes_cache=(); folder_total_cache=(); cached_folder_total_bytes=(); modified_cache=(); cached_folder_checked=(); cached_folder_status=(); page=0
                                ;;
                            *) echo "Refresh cancelled." ;;
                        esac
                        ;;
                    i|I)
                        read -r -e -p "Items per page (1-200): " new_page_size
                        if [[ "$new_page_size" =~ ^[0-9]+$ ]] && [ "$new_page_size" -ge 1 ] && [ "$new_page_size" -le 200 ]; then
                            page_size="$new_page_size"
                            ITEMS_PER_PAGE="$new_page_size"
                            save_preference "ITEMS_PER_PAGE" "$new_page_size" || true
                            page=0
                            notice="Items per page saved: $new_page_size"
                        else
                            echo "❌ Enter a whole number from 1 to 200."
                        fi
                        ;;
                    d|D)
                        echo "  Saved default: $DEFAULT_FILE_SORT_ORDER (used by host and Docker folder lists)"
                        echo "  [1] Alphabetical  [2] Largest first  [3] Smallest first  [4] Most recently updated first"
                        read -r -e -p "> " default_sort_choice
                        case "$default_sort_choice" in
                            1) default_sort_value="alphabetical" ;;
                            2) default_sort_value="largest" ;;
                            3) default_sort_value="smallest" ;;
                            4) default_sort_value="updated" ;;
                            *) echo "❌ Enter 1, 2, 3, or 4."; continue ;;
                        esac
                        if { [ "$default_sort_value" != "largest" ] && [ "$default_sort_value" != "smallest" ]; } || [ "$SHOW_FILE_SIZES" = "on" ]; then
                            if save_default_file_order "$default_sort_value"; then
                                notice="Display order saved for Walker and Docker folders: $default_sort_value"
                                page=0
                            fi
                        else
                            echo "❌ Largest/smallest requires file-size calculations to be on."
                        fi
                        ;;
                    e|E)
                        echo "  [1] Mark this folder and all descendants as encrypted"
                        echo "  [2] Mark only this folder as encrypted"
                        echo "  [3] Remove this folder's encryption label"
                        echo "  [q] Cancel"
                        read -r -e -p "> " encryption_choice
                        case "$encryption_choice" in
                            1) python3 "$SCRIPT_DIR/wombat-walker-db.py" set-encryption "$WALKER_DATABASE" "$current" descendants && load_encryption_labels ;;
                            2) python3 "$SCRIPT_DIR/wombat-walker-db.py" set-encryption "$WALKER_DATABASE" "$current" self && load_encryption_labels ;;
                            3) python3 "$SCRIPT_DIR/wombat-walker-db.py" remove-encryption "$WALKER_DATABASE" "$current" && load_encryption_labels ;;
                            q|Q|"") ;;
                            *) echo "❌ Enter 1, 2, 3, or q." ;;
                        esac
                        ;;
                    m|M)
                        mount_storage_menu
                        ;;
                    c|C) docker_workspace ;;
                    '!')
                        echo "Opening a normal user shell in: $current"
                        echo "Type exit to return to Wombat Walker."
                        (
                            cd "$current" || exit 1
                            "${SHELL:-/bin/bash}"
                        )
                        ;;
                    b|B) bulk_cleanup_preview "$current" || true ;;
                    t|T) wombat_trash_manager purge ;;
                    z|Z) wombat_trash_manager restore ;;
                    l|L)
                        echo
                        python3 "$SCRIPT_DIR/wombat-walker-db.py" operation-list "$WALKER_DATABASE" || echo "❌ Could not read the Wombat Trash audit log."
                        echo
                        read -r -e -p "Press Enter to return to Utilities. " _
                        ;;
                    f|F)
                        if [ "$SHOW_FILE_SIZES" = "on" ]; then
                            SHOW_FILE_SIZES="off"
                            if [ "$SORT_ORDER" = "largest" ] || [ "$SORT_ORDER" = "smallest" ]; then
                                SORT_ORDER="alphabetical"
                            fi
                            echo "File-size calculations are off for this Walker session."
                        else
                            SHOW_FILE_SIZES="on"
                            echo "File-size display is on; saved scan data will be used when available."
                        fi
                        page=0
                        ;;
                    h|H) [ "$SHOW_HIDDEN" = "on" ] && SHOW_HIDDEN="off" || SHOW_HIDDEN="on"; page=0 ;;
                    g|G)
                        managed_folder="$current"
                        file_management_menu "$managed_folder" || true
                        if [[ "${FILE_MANAGEMENT_RESULT:-}" =~ ^(copy|move|rename|trash)$ ]]; then
                            back_history+=("$managed_folder")
                            current="$(dirname "$managed_folder")"
                            page=0
                        fi
                        ;;
                    \?)
                        walker_help_screen
                        read -r -e -p "Press Enter to return to Utilities. " _
                        ;;
                    q|Q|"") ;;
                    *) echo "❌ Enter r, v, i, e, m, c, b, t, z, l, f, h, g, ?, or q." ;;
                esac
                ;;
            o|O)
                echo "  [1] Alphabetical  [2] Largest first  [3] Smallest first  [4] Most recently updated first"
                read -r -e -p "> " sort_choice
                case "$sort_choice" in
                    1) save_default_file_order alphabetical && notice="Display order saved: alphabetical" ;;
                    2) [ "$SHOW_FILE_SIZES" = "on" ] && save_default_file_order largest && notice="Display order saved: largest first" || notice="❌ Largest-first order requires file-size calculations to be on." ;;
                    3) [ "$SHOW_FILE_SIZES" = "on" ] && save_default_file_order smallest && notice="Display order saved: smallest first" || notice="❌ Smallest-first order requires file-size calculations to be on." ;;
                    4) save_default_file_order updated && notice="Display order saved: most recently updated first" ;;
                    *) notice="❌ Enter 1, 2, 3, or 4." ;;
                esac
                page=0
                ;;
            m|M)
                read -r -e -p "Enter path (/home/wombat or ~/ for home; q to cancel): " manual_path
                case "$manual_path" in q|Q|"") notice="Path entry cancelled."; continue ;; esac
                if [ "$manual_path" = "~" ]; then
                    manual_path="$HOME"
                elif [[ "$manual_path" == "~/"* ]]; then
                    manual_path="$HOME/${manual_path#\~/}"
                fi
                if [ ! -e "$manual_path" ]; then
                    notice="❌ That path does not exist. Press m first, then enter an absolute path beginning with /, such as /home/wombat."
                    continue
                fi
                if [ -d "$manual_path" ]; then
                    back_history+=("$current"); current="$(realpath "$manual_path")"; page=0; notice=""
                elif [ -f "$manual_path" ] && [ ! -L "$manual_path" ]; then
                    file_action_menu "$(realpath "$manual_path")"
                elif [ -L "$manual_path" ]; then
                    notice="❌ Cannot edit this selection: it is a symbolic link. Resolve or manage symbolic links outside Wombat Walker."
                else
                    notice="❌ This is not a regular file. Manage folders, devices, and special files outside Wombat Walker."
                fi
                ;;
            s|S)
                search_combined="off"
                search_direct="off"
                search_scope=""
                search_folder_label="$(basename "$current")"
                [ "$current" = "/" ] && search_folder_label="/"
                echo "Where do you want to search?"
                echo "  [1] This folder only: $search_folder_label"
                echo "  [2] This folder and all descendants: $search_folder_label"
                echo "  [3] Search every saved host-folder scan"
                echo "  [4] Choose another folder"
                echo "  [5] Search saved host and Docker scans"
                read -r -e -p "> " search_scope_choice
                case "$search_scope_choice" in
                    1) search_scope="$current"; search_direct="on" ;;
                    2) search_scope="$current" ;;
                    3) search_scope="" ;;
                    4)
                        search_folder_picker_entries=("${all_entries[@]}")
                        search_folder_picker_page=0
                        search_folder_picker_total="${#search_folder_picker_entries[@]}"
                        if [ "$search_folder_picker_total" -eq 0 ]; then
                            notice="❌ There are no folders to choose in: $current"
                            continue
                        fi
                        while true; do
                            search_folder_picker_start=$((search_folder_picker_page * page_size))
                            search_folder_picker_end=$((search_folder_picker_start + page_size))
                            [ "$search_folder_picker_end" -gt "$search_folder_picker_total" ] && search_folder_picker_end="$search_folder_picker_total"
                            echo
                            echo "=================================================================================================="
                            echo "Choose a folder to search in: $current"
                            echo "Order: $SORT_ORDER    Items per page: $page_size    Hidden: $SHOW_HIDDEN"
                            echo "=================================================================================================="
                            printf "  %-5s%-10s%-32s %12s  %12s  %-14s %-16s\n" "No." "Type" "Name" "Logical size" "On disk" "Owner" "Last updated"
                            for ((search_folder_index=search_folder_picker_start; search_folder_index<search_folder_picker_end; search_folder_index++)); do
                                search_folder_candidate="${search_folder_picker_entries[$search_folder_index]}"
                                search_folder_name="$(basename "$search_folder_candidate")"
                                if [ -d "$search_folder_candidate" ] && [ ! -L "$search_folder_candidate" ]; then search_folder_kind="dir"; else search_folder_kind="file"; fi
                                [ "${#search_folder_name}" -le 32 ] || search_folder_name="${search_folder_name:0:29}..."
                                measure_item "$search_folder_candidate"; modified_time "$search_folder_candidate"; file_owner "$search_folder_candidate"
                                printf "  %-5s%-10s%-32s %12s  %12s  %-14s %-16s\n" "[$((search_folder_index + 1))]" "$search_folder_kind" "$search_folder_name" "${size_cache[$search_folder_candidate]:-}" "${on_disk_cache[$search_folder_candidate]:-}" "$OWNER_DISPLAY" "${modified_cache[$search_folder_candidate]:-}"
                            done
                            echo
                            [ "$search_folder_picker_end" -lt "$search_folder_picker_total" ] && printf "  %-34s" "[n] Next page"
                            [ "$search_folder_picker_page" -gt 0 ] && printf "%-34s" "[p] Previous page"
                            if [ -n "$notice" ]; then
                                echo "  $notice"
                                notice=""
                            fi
                            printf "%s\n" "[o] Change folder order    [m] Type a path manually    [q] Cancel"
                            read -r -e -p "Choose a displayed folder number, n/p/o/m/q: " search_folder_choice
                            case "$search_folder_choice" in
                                q|Q|"") notice="Search cancelled."; break ;;
                                n|N)
                                    [ "$search_folder_picker_end" -lt "$search_folder_picker_total" ] && search_folder_picker_page=$((search_folder_picker_page + 1)) || notice="❌ This is the last folder page."
                                    ;;
                                p|P)
                                    [ "$search_folder_picker_page" -gt 0 ] && search_folder_picker_page=$((search_folder_picker_page - 1)) || notice="❌ This is the first folder page."
                                    ;;
                                o|O)
                                    echo "  [1] Alphabetical  [2] Largest first  [3] Smallest first  [4] Most recently updated"
                                    read -r -e -p "> " search_folder_order_choice
                                    case "$search_folder_order_choice" in
                                        1) SORT_ORDER="alphabetical" ;; 2) SORT_ORDER="largest" ;; 3) SORT_ORDER="smallest" ;; 4) SORT_ORDER="updated" ;;
                                        *) notice="❌ Enter 1, 2, 3, or 4."; continue ;;
                                    esac
                                    entries=("${search_folder_picker_entries[@]}")
                                    sort_entries
                                    search_folder_picker_entries=("${entries[@]}")
                                    search_folder_picker_page=0
                                    ;;
                                m|M)
                                    read -r -e -p "Enter absolute folder path (start with /, e.g. /home/wombat; q to cancel): " search_manual_folder
                                    case "$search_manual_folder" in
                                        q|Q|"") notice="Search cancelled."; break ;;
                                    esac
                                    if [ "$search_manual_folder" = "~" ]; then
                                        search_manual_folder="$HOME"
                                    elif [[ "$search_manual_folder" == "~/"* ]]; then
                                        search_manual_folder="$HOME/${search_manual_folder#\~/}"
                                    fi
                                    if [ ! -d "$search_manual_folder" ] || [ ! -r "$search_manual_folder" ] || [ ! -x "$search_manual_folder" ]; then
                                        notice="❌ That folder is unavailable or cannot be read: $search_manual_folder"
                                    else
                                        search_scope="$(realpath "$search_manual_folder")"
                                        break
                                    fi
                                    ;;
                                *)
                                    if ! [[ "$search_folder_choice" =~ ^[0-9]+$ ]] || [ "$search_folder_choice" -lt 1 ] || [ "$search_folder_choice" -gt "$search_folder_picker_total" ] || [ "$search_folder_choice" -lt $((search_folder_picker_start + 1)) ] || [ "$search_folder_choice" -gt "$search_folder_picker_end" ]; then
                                        notice="❌ Enter a displayed folder number, n, p, o, m, or q."
                                    elif [ ! -d "${search_folder_picker_entries[$((search_folder_choice - 1))]}" ] || [ -L "${search_folder_picker_entries[$((search_folder_choice - 1))]}" ]; then
                                        notice="❌ That item is a file. Choose a row marked dir."
                                    else
                                        search_scope="$(realpath "${search_folder_picker_entries[$((search_folder_choice - 1))]}")"
                                        break
                                    fi
                                    ;;
                            esac
                        done
                        [ -n "$search_scope" ] || continue
                        back_history+=("$current")
                        current="$search_scope"
                        page=0
                        ;;
                    5) search_scope=""; search_combined="on" ;;
                    q|Q|"") notice="Search cancelled."; continue ;;
                    *) notice="❌ Enter 1, 2, 3, 4, 5, or q."; continue ;;
                esac
                if [ -n "$search_scope" ]; then
                    echo "This search will refresh: $search_scope"
                    read -r -e -p "Refresh this folder before searching? [Y/n] " search_refresh_choice
                    case "$search_refresh_choice" in
                        n|N|no|NO) ;;
                        *)
                            echo "Refreshing Walker's saved search index below: $search_scope"
                            if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" scan "$WALKER_DATABASE" "$search_scope" little 2>/dev/null; then
                                notice="❌ Could not refresh this folder's search index. Search was cancelled."
                                continue
                            fi
                            ;;
                    esac
                fi
                read -r -e -p "Enter search words (q to cancel): " search_words
                case "$search_words" in
                    q|Q|"") notice="Search cancelled."; continue ;;
                esac
                search_min_size=""
                search_max_size=""
                search_offset=0
                search_order="relevance"
                while true; do
                    echo
                    if [ "$search_combined" = "on" ]; then
                        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" combined-search "$WALKER_DATABASE" "$search_words" "$SEARCH_LIMIT" "$search_offset" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null; then
                            notice="❌ Search failed. Check the search words and filters, then try again."
                            break
                        fi
                    elif [ "$search_direct" = "on" ]; then
                        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" search-direct "$WALKER_DATABASE" "$search_words" - "$SEARCH_LIMIT" "$search_offset" "$search_scope" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null; then
                            notice="❌ Search failed. Check the search words and filters, then try again."
                            break
                        fi
                    elif [ -n "$search_scope" ]; then
                        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$WALKER_DATABASE" "$search_words" - "$SEARCH_LIMIT" "$search_offset" "$search_scope" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null; then
                            notice="❌ Search failed. Check the search words and filters, then try again."
                            break
                        fi
                    else
                        if ! python3 "$SCRIPT_DIR/wombat-walker-db.py" search "$WALKER_DATABASE" "$search_words" - "$SEARCH_LIMIT" "$search_offset" - "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null; then
                            notice="❌ Search failed. Check the search words and filters, then try again."
                            break
                        fi
                    fi
                    echo "  [n] Next page    [p] Previous page    [o] Change result order    [f] Refine search    [r] New search words    [x] Utilities    [q] Return"
                    read -r -e -p "Open result number, or choose n/p/o/f/r/x/q: " search_result_number
                    case "$search_result_number" in
                        q|Q|"") break ;;
                        n|N) search_offset=$((search_offset + SEARCH_LIMIT)); continue ;;
                        p|P)
                            if [ "$search_offset" -ge "$SEARCH_LIMIT" ]; then search_offset=$((search_offset - SEARCH_LIMIT)); else echo "❌ This is the first search-results page."; fi
                            continue
                            ;;
                        o|O)
                            echo "  [1] Alphabetical  [2] Largest first  [3] Smallest first  [4] Most recently updated"
                            read -r -e -p "> " search_order_choice
                            case "$search_order_choice" in
                                1) search_order="relevance" ;; 2) search_order="largest" ;;
                                3) search_order="smallest" ;; 4) search_order="updated" ;;
                                *) echo "❌ Enter 1, 2, 3, or 4."; continue ;;
                            esac
                            search_offset=0
                            continue
                            ;;
                        f|F)
                            read -r -e -p "Minimum logical size (blank for none, e.g. 100MB): " search_min_size
                            read -r -e -p "Maximum logical size (blank for none): " search_max_size
                            search_offset=0
                            continue
                            ;;
                        r|R)
                            read -r -e -p "Enter new search words (q to cancel): " search_words
                            case "$search_words" in
                                q|Q|"") break ;;
                            esac
                            search_min_size=""
                            search_max_size=""
                            search_offset=0
                            continue
                            ;;
                        x|X)
                            search_utilities_menu
                            continue
                            ;;
                    esac
                    if ! [[ "$search_result_number" =~ ^[0-9]+$ ]] || [ "$search_result_number" -le "$search_offset" ] || [ "$search_result_number" -gt $((search_offset + SEARCH_LIMIT)) ]; then
                        echo "❌ Enter a result number shown on this page, n, p, o, f, r, x, or q."
                        continue
                    fi
                    if [ "$search_combined" = "on" ]; then
                        combined_result_fields=()
                        mapfile -d '' -t combined_result_fields < <(python3 "$SCRIPT_DIR/wombat-walker-db.py" combined-search-path "$WALKER_DATABASE" "$search_words" "$search_result_number" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null || true)
                        cached_path="${combined_result_fields[4]:-}"
                    elif [ "$search_direct" = "on" ]; then
                        cached_path="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" search-direct-path "$WALKER_DATABASE" "$search_words" - "$search_result_number" "$search_scope" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null || true)"
                    elif [ -n "$search_scope" ]; then
                        cached_path="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" search-path "$WALKER_DATABASE" "$search_words" - "$search_result_number" "$search_scope" "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null || true)"
                    else
                        cached_path="$(python3 "$SCRIPT_DIR/wombat-walker-db.py" search-path "$WALKER_DATABASE" "$search_words" - "$search_result_number" - "$search_order" "$search_min_size" "$search_max_size" 2>/dev/null || true)"
                    fi
                    break
                done
                [ -n "${search_result_number:-}" ] && [[ "$search_result_number" =~ ^[0-9]+$ ]] || continue
                if [ -z "$cached_path" ]; then
                    notice="❌ That result is outside the displayed search results."
                    continue
                fi
                if [ -e "$cached_path" ] || [ -L "$cached_path" ]; then
                    echo
                    echo "Selected search result: $cached_path"
                    if [ -f "$cached_path" ] && [ ! -L "$cached_path" ]; then
                        echo "  [o] Open file (view or edit)"
                    elif [ -d "$cached_path" ] && [ ! -L "$cached_path" ]; then
                        echo "  [o] Browse this folder"
                    else
                        echo "  [o] Open this result"
                    fi
                    echo "  [g] Manage search result (copy, move, rename, Trash)"
                    echo "  [q] Return to search results"
                    read -r -e -p "> " search_result_action
                    case "$search_result_action" in
                        g|G)
                            file_management_menu "$cached_path" || true
                            if [ -n "${FILE_MANAGEMENT_RESULT:-}" ]; then
                                python3 "$SCRIPT_DIR/wombat-walker-db.py" mark-stale "$WALKER_DATABASE" "$(dirname "$cached_path")" >/dev/null 2>&1 || true
                                echo "Search result management completed: ${FILE_MANAGEMENT_RESULT^}."
                                FILE_MANAGEMENT_RESULT=""
                            fi
                            continue
                            ;;
                        q|Q|"") continue ;;
                    esac
                fi
                if [ "$search_combined" = "on" ] && [ "${combined_result_fields[0]:-}" = "docker" ]; then
                    if [ "${combined_result_fields[3]:-}" = "directory" ]; then
                        browse_docker_container "${combined_result_fields[1]}" "${combined_result_fields[2]}" "$cached_path"
                    else
                        browse_docker_container "${combined_result_fields[1]}" "${combined_result_fields[2]}" "$(dirname "$cached_path")"
                    fi
                    continue
                fi
                if [ ! -e "$cached_path" ]; then
                    echo "❌ Cached result is no longer present: $cached_path"
                    echo "  Refresh the relevant folder before relying on this result."
                elif [ -d "$cached_path" ] && [ -r "$cached_path" ] && [ -x "$cached_path" ]; then
                    back_history+=("$current"); current="$(realpath "$cached_path")"; page=0
                elif [ -d "$cached_path" ]; then
                    echo "Protected folder: $cached_path"
                    echo "You do not have permission to inspect its contents."
                    read -r -e -p "Request temporary sudo access to browse it? [y/N] " REQUEST_ELEVATION
                    case "$REQUEST_ELEVATION" in
                        y|Y|yes|YES) browse_protected_folder "$cached_path" ;;
                        *) echo "Returned without requesting elevated access." ;;
                    esac
                elif [ -f "$cached_path" ] && [ ! -L "$cached_path" ]; then
                    file_action_menu "$cached_path"
                elif [ -L "$cached_path" ]; then
                    echo "❌ Cannot edit this selection: it is a symbolic link."
                    echo "  Resolve or manage the link outside Wombat Walker, then select the actual regular file."
                else
                    echo "Protected file: $cached_path"
                    echo "You do not have permission to inspect this file."
                    read -r -e -p "Request temporary sudo access to view it safely? [y/N] " REQUEST_ELEVATION
                    case "$REQUEST_ELEVATION" in
                        y|Y|yes|YES)
                            if [ "$PRIVILEGED_MODE" = "on" ]; then
                                sudo "$SCRIPT_DIR/wombat-walker-privileged.sh" view-file "$cached_path"
                            else
                                echo "❌ Protected viewing is unavailable in this user-only Walker install."
                            fi
                            ;;
                        *) echo "Returned without requesting elevated access." ;;
                    esac
                fi
                ;;
            q|Q) echo "Cancelled."; return 0 ;;
            *)
                if [[ "$choice" == /* || "$choice" == "~" || "$choice" == "~/"* ]]; then
                    manual_path="$choice"
                    [ "$manual_path" = "~" ] && manual_path="$HOME"
                    [[ "$manual_path" == "~/"* ]] && manual_path="$HOME/${manual_path#\~/}"
                    if [ -d "$manual_path" ]; then
                        back_history+=("$current"); current="$(realpath "$manual_path")"; page=0; notice=""
                    elif [ -f "$manual_path" ] && [ ! -L "$manual_path" ]; then
                        file_action_menu "$(realpath "$manual_path")"
                    else
                        notice="❌ That path does not exist or is not an ordinary folder/file: $choice"
                    fi
                elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
                    child="${entries[$((choice - 1))]}"
                    if [ -d "$child" ] && [ ! -L "$child" ]; then back_history+=("$current"); current="$(realpath "$child")"; page=0
                    elif [ -f "$child" ] && [ ! -L "$child" ]; then file_action_menu "$(realpath "$child")"
                    elif [ -L "$child" ]; then
                        echo "❌ Cannot edit this selection: it is a symbolic link."
                        echo "  Resolve or manage the link outside Wombat Walker, then select the actual regular file."
                    else
                        echo "❌ This selection is not an ordinary regular file. Manage it outside Wombat Walker."
                    fi
                else
                    notice="❌ Enter a listed number, a path such as /home/wombat or ~/, ., !, u, d, n, p, m, s, o, x, or q."
                fi
                ;;
        esac
    done
}

if [ "$DOCKER_LAUNCH" = "on" ]; then
    docker_workspace
fi
if [ "$DISK_HEALTH_LAUNCH" = "on" ]; then
    disk_health_checker
fi
walk_filesystem
