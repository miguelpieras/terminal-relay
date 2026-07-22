#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
source_directory="$repository_root/Server/worker-config"

for source_name in AGENTS.md CLAUDE.md install.sh; do
    if [[ ! -f "$source_directory/$source_name" ]]; then
        echo "Missing worker guidance source: $source_directory/$source_name" >&2
        exit 1
    fi
done

if [[ "$#" -eq 0 ]]; then
    set -- terminal-relay-worker-1
fi

for target in "$@"; do
    if [[ -z "$target" || "$target" == -* || "$target" == *$'\n'* ]]; then
        echo "Invalid SSH target: $target" >&2
        exit 2
    fi

    echo "Syncing worker guidance to $target"
    /usr/bin/tar --no-xattrs -C "$source_directory" -cf - . | /usr/bin/ssh "$target" '
set -eu

temporary_root=${TMPDIR:-/tmp}
case "$temporary_root" in
    /*) ;;
    *)
        echo "Refusing to use a non-absolute temporary root: $temporary_root" >&2
        exit 1
        ;;
esac

if [ ! -d "$temporary_root" ]; then
    echo "Temporary root does not exist: $temporary_root" >&2
    exit 1
fi

temporary_root=$(cd "$temporary_root" && pwd -P)
temporary_directory=$(mktemp -d "$temporary_root/terminal-relay-worker-config.XXXXXX")

cleanup() {
    cleanup_exit_code=$?
    trap - 0

    if [ -n "${temporary_directory:-}" ] && { [ -e "$temporary_directory" ] || [ -L "$temporary_directory" ]; }; then
        temporary_parent=$(dirname "$temporary_directory")
        temporary_name=$(basename "$temporary_directory")
        case "$temporary_name" in
            terminal-relay-worker-config.*) ;;
            *)
                echo "Refusing to clean unexpected temporary path: $temporary_directory" >&2
                exit 1
                ;;
        esac
        if [ "$temporary_parent" != "$temporary_root" ]; then
            echo "Refusing to clean temporary path outside $temporary_root: $temporary_directory" >&2
            exit 1
        fi
        rm -rf -- "$temporary_directory"
    fi

    exit "$cleanup_exit_code"
}
trap cleanup 0

tar -xf - -C "$temporary_directory"
/bin/bash "$temporary_directory/install.sh"
'
done
