#!/usr/bin/env bash
# Install Wombat Walker as the `wombat-walker` command.
set -euo pipefail

MODE="system"
WITH_DOCKER="off"
SKIP_DEPS="off"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: install-wombat-walker.sh [--user|--system] [--with-docker] [--skip-deps]

Installs the `wombat-walker` command so it can be run from any folder.

The normal system install uses sudo once and keeps program files root-owned. This safely enables
Walker's explicit protected-folder features. If you do not have sudo/root access on the machine,
use --user instead: ordinary Walker and Docker features still work, but protected host browsing and
editing are unavailable.

  --system        Install to /opt/wombat-walker and /usr/local/bin (default when sudo is available)
  --user          Install to ~/.local/share/wombat-walker and ~/.local/bin (no sudo)
  --with-docker   Also install Docker if it is missing; Docker service/group setup remains explicit
  --skip-deps     Do not install packages; only verify the required commands and install Walker
  --help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --system) MODE="system" ;;
        --user) MODE="user" ;;
        --with-docker) WITH_DOCKER="on" ;;
        --skip-deps) SKIP_DEPS="on" ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌ Unknown installer option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if [ "$MODE" = "system" ] && [ "${EUID}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        if ! sudo -v; then
            echo "⚠️  Sudo access is not available here, so Walker will use a user-only install."
            echo "   It will run normally, but protected host browsing and editing will be unavailable."
            MODE="user"
        fi
    else
        echo "⚠️  You do not have sudo/root access here, so Walker will use a user-only install."
        echo "   It will run normally, but protected host browsing and editing will be unavailable."
        MODE="user"
    fi
fi

package_manager=""
command -v apt-get >/dev/null 2>&1 && package_manager="apt"
command -v pacman >/dev/null 2>&1 && package_manager="pacman"
command -v dnf >/dev/null 2>&1 && package_manager="dnf"
command -v zypper >/dev/null 2>&1 && package_manager="zypper"
command -v apk >/dev/null 2>&1 && package_manager="apk"

install_packages() {
    local -a packages=("$@")
    [ "${#packages[@]}" -gt 0 ] || return 0
    case "$package_manager" in
        apt) sudo apt-get update && sudo apt-get install -y "${packages[@]}" ;;
        pacman) sudo pacman -Sy --needed --noconfirm "${packages[@]}" ;;
        dnf) sudo dnf install -y "${packages[@]}" ;;
        zypper) sudo zypper --non-interactive install "${packages[@]}" ;;
        apk) sudo apk add "${packages[@]}" ;;
        *) echo "❌ No supported package manager was found. Install dependencies manually." >&2; return 1 ;;
    esac
}

if [ "$SKIP_DEPS" != "on" ]; then
    case "$package_manager" in
        apt) packages=(bash coreutils findutils gawk sed grep util-linux python3 less nano vim); [ "$WITH_DOCKER" = on ] && packages+=(docker.io) ;;
        pacman) packages=(bash coreutils findutils gawk sed grep util-linux python less nano vim); [ "$WITH_DOCKER" = on ] && packages+=(docker) ;;
        dnf) packages=(bash coreutils findutils gawk sed grep util-linux python3 less nano vim-enhanced); [ "$WITH_DOCKER" = on ] && packages+=(moby-engine) ;;
        zypper) packages=(bash coreutils findutils gawk sed grep util-linux python3 less nano vim); [ "$WITH_DOCKER" = on ] && packages+=(docker) ;;
        apk) packages=(bash coreutils findutils gawk sed grep util-linux python3 less nano vim); [ "$WITH_DOCKER" = on ] && packages+=(docker) ;;
        *) packages=() ;;
    esac
    if [ "${#packages[@]}" -gt 0 ]; then
        echo "Walker needs standard shell tools plus Python 3. Install/confirm these packages?"
        printf '  %s\n' "${packages[*]}"
        read -r -p "Continue? [Y/n] " answer
        case "${answer:-Y}" in y|Y|yes|YES) install_packages "${packages[@]}" ;; *) echo "Package installation skipped." ;; esac
    fi
fi

for required in bash python3 find stat du df sort awk sed grep realpath mktemp mountpoint; do
    command -v "$required" >/dev/null 2>&1 || { echo "❌ Missing required command: $required" >&2; exit 1; }
done
python3 - <<'PY'
import sqlite3
connection = sqlite3.connect(":memory:")
connection.execute("CREATE VIRTUAL TABLE walker_test USING fts5(value)")
PY

if [ "$MODE" = "system" ]; then
    install_root="/opt/wombat-walker"
    launcher="/usr/local/bin/wombat-walker"
    run_install() { sudo install "$@"; }
else
    install_root="${XDG_DATA_HOME:-$HOME/.local/share}/wombat-walker"
    launcher="${HOME}/.local/bin/wombat-walker"
    run_install() { install "$@"; }
fi

run_install -d -m 0755 "$install_root"
for file in wombat-walker.sh wombat-walker-db.py wombat-walker-trash.py wombat-walker-privileged.sh wombat-walker-privileged-list.py; do
    [ -f "$SOURCE_DIR/$file" ] || { echo "❌ Installer source is missing: $file" >&2; exit 1; }
    case "$file" in *.sh) run_install -m 0755 "$SOURCE_DIR/$file" "$install_root/$file" ;; *) run_install -m 0644 "$SOURCE_DIR/$file" "$install_root/$file" ;; esac
done

if [ "$MODE" = "system" ]; then
    printf '%s\n' '#!/bin/sh' "exec '$install_root/wombat-walker.sh' \"\$@\"" | sudo tee "$launcher" >/dev/null
    sudo chmod 0755 "$launcher"
    sudo install -d -m 0700 /var/lib/wombat-walker
    sudo "$install_root/wombat-walker-privileged.sh" init-db >/dev/null
else
    install -d -m 0755 "$(dirname "$launcher")"
    printf '%s\n' '#!/bin/sh' 'export WOMBAT_WALKER_PRIVILEGED_MODE=off' "exec '$install_root/wombat-walker.sh' \"\$@\"" > "$launcher"
    chmod 0755 "$launcher"
fi

echo "✅ Wombat Walker installed: $launcher"
if [ "$MODE" = "user" ] && [[ ":$PATH:" != *":$(dirname "$launcher"):"* ]]; then
    echo "Add $(dirname "$launcher") to PATH, then open a new terminal before running wombat-walker."
fi
if [ "$WITH_DOCKER" = "on" ] && ! docker info >/dev/null 2>&1; then
    echo "Docker was installed but is not ready for this user. Start its service and deliberately add the user to the docker group if wanted."
fi
echo "Run: wombat-walker --home"
