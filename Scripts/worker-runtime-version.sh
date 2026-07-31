#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
payload_list="$repository_root/Server/worker-runtime-files.txt"
runtime_paths=(Server/worker-runtime-files.txt)

[[ -f "$payload_list" && ! -L "$payload_list" ]] || {
    echo "worker-runtime-version: canonical payload list is unavailable" >&2
    exit 66
}

while IFS= read -r source_name; do
    [[ "$source_name" != */* && -f "$repository_root/Server/$source_name" ]] || {
        echo "worker-runtime-version: invalid runtime payload source" >&2
        exit 66
    }
    runtime_paths+=("Server/$source_name")
done < <(/usr/bin/awk -F'|' '!/^#/ && NF { print $1 }' "$payload_list")

runtime_version="$(git -C "$repository_root" log -1 --format=%ct -- "${runtime_paths[@]}")"
[[ "$runtime_version" =~ ^[1-9][0-9]*$ ]] || {
    echo "worker-runtime-version: could not derive the runtime payload version" >&2
    exit 65
}

printf '%s\n' "$runtime_version"
