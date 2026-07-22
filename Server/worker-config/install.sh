#!/bin/bash
set -euo pipefail

config_directory="$(cd "$(dirname "$0")" && pwd)"
worker_home="${HOME:?HOME must be set}"

if [[ "$worker_home" != /* || ! -d "$worker_home" ]]; then
    echo "Refusing to install with an invalid home directory: $worker_home" >&2
    exit 1
fi

for source_name in AGENTS.md CLAUDE.md; do
    if [[ ! -f "$config_directory/$source_name" ]]; then
        echo "Missing worker guidance source: $config_directory/$source_name" >&2
        exit 1
    fi
done

backup_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

install_guidance() {
    local source_name="$1"
    local destination="$2"
    local source_path="$config_directory/$source_name"
    local backup_path=""
    local backup_suffix=1

    mkdir -p "$(dirname "$destination")"

    if [[ -f "$destination" ]] && cmp -s "$source_path" "$destination"; then
        echo "Already current: $destination"
        return
    fi

    if [[ -e "$destination" || -L "$destination" ]]; then
        backup_path="$destination.backup.$backup_timestamp"
        while [[ -e "$backup_path" || -L "$backup_path" ]]; do
            backup_path="$destination.backup.$backup_timestamp.$backup_suffix"
            backup_suffix=$((backup_suffix + 1))
        done
        mv -- "$destination" "$backup_path"
        echo "Backed up $destination to $backup_path"
    fi

    if ! install -m 0644 "$source_path" "$destination"; then
        if [[ -n "$backup_path" ]]; then
            mv -f -- "$backup_path" "$destination"
        fi
        return 1
    fi

    echo "Installed $destination"
}

install_guidance AGENTS.md "$worker_home/AGENTS.md"
install_guidance CLAUDE.md "$worker_home/CLAUDE.md"
install_guidance AGENTS.md "$worker_home/.codex/AGENTS.md"
install_guidance CLAUDE.md "$worker_home/.claude/CLAUDE.md"
