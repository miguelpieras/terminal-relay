#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
server_directory="$repository_root/Server"
payload_list="$server_directory/worker-runtime-files.txt"
public_key="${TERMINAL_RELAY_RUNTIME_PUBLIC_KEY_PATH:-$server_directory/terminal-relay-runtime-update.pub}"
feed_root="${TERMINAL_RELAY_RUNTIME_FEED_ROOT:-https://miguelpieras.github.io/terminal-relay/worker-runtime}"
openssl_bin="${OPENSSL_BIN:-$(command -v openssl || true)}"
expected_version="$("$script_directory/worker-runtime-version.sh")"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_directory="$(/usr/bin/mktemp -d "$temporary_root/terminal-relay-stable-runtime.XXXXXX")"

cleanup() {
    local exit_code=$?

    trap - EXIT
    case "$temporary_directory" in
        "$temporary_root"/terminal-relay-stable-runtime.*)
            /bin/rm -rf -- "$temporary_directory"
            ;;
        *) exit_code=1 ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT

[[ -x "$openssl_bin" && -f "$public_key" && ! -L "$public_key" ]] || {
    echo "verify-published-worker-runtime: runtime signature verifier is unavailable" >&2
    exit 69
}

download() {
    local name="$1"
    local destination="$temporary_directory/$name"

    if [[ "$feed_root" == https://* ]]; then
        /usr/bin/curl \
            --proto '=https' \
            --tlsv1.2 \
            --fail \
            --location \
            --silent \
            --show-error \
            --connect-timeout 5 \
            --max-time 20 \
            --retry 2 \
            --retry-delay 2 \
            --output "$destination" \
            "$feed_root/$name"
        return
    fi
    if [[ "${TERMINAL_RELAY_ALLOW_LOCAL_RUNTIME_FEED:-}" == 1 \
        && "$feed_root" == file:///* ]]; then
        /bin/cp "${feed_root#file://}/$name" "$destination"
        return
    fi
    echo "verify-published-worker-runtime: runtime feed must use HTTPS" >&2
    exit 64
}

download manifest.json
download manifest.sig
"$openssl_bin" pkeyutl \
    -verify \
    -pubin \
    -inkey "$public_key" \
    -rawin \
    -in "$temporary_directory/manifest.json" \
    -sigfile "$temporary_directory/manifest.sig" >/dev/null 2>&1 || {
        echo "verify-published-worker-runtime: stable runtime signature is invalid" >&2
        exit 65
    }

/usr/bin/python3 - \
    "$server_directory" \
    "$payload_list" \
    "$temporary_directory/manifest.json" \
    "$expected_version" <<'PYTHON'
import hashlib
import json
import pathlib
import re
import sys

server = pathlib.Path(sys.argv[1])
payload_list = pathlib.Path(sys.argv[2])
manifest_path = pathlib.Path(sys.argv[3])
expected_version = int(sys.argv[4])
stable_root = "https://miguelpieras.github.io/terminal-relay/worker-runtime"

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, ValueError) as error:
    raise SystemExit("published stable runtime manifest is invalid") from error

expected_files = []
for raw_line in payload_list.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    source_name, destination, mode = line.split("|")
    source = server / source_name
    expected_files.append(
        {
            "source": source_name,
            "destination": destination,
            "mode": mode,
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        }
    )

version = manifest.get("runtimeVersion")
if (
    set(manifest)
    != {
        "schemaVersion",
        "channel",
        "runtimeVersion",
        "releaseVersion",
        "protocol",
        "capabilities",
        "archiveURL",
        "archiveSHA256",
        "files",
    }
    or manifest.get("schemaVersion") != 1
    or manifest.get("channel") != "stable"
    or version != expected_version
    or manifest.get("protocol") != {"minimum": 1, "maximum": 2}
    or manifest.get("capabilities")
    != [
        "agent-sessions",
        "chat-v1",
        "runtime-updates-v1",
        "threads-v1",
        "threads-v2",
    ]
    or not isinstance(manifest.get("releaseVersion"), str)
    or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", manifest["releaseVersion"])
    or manifest.get("archiveURL")
    != f"{stable_root}/{expected_version}/runtime.tar.gz"
    or not isinstance(manifest.get("archiveSHA256"), str)
    or not re.fullmatch(r"[a-f0-9]{64}", manifest["archiveSHA256"])
    or manifest.get("files") != expected_files
):
    raise SystemExit(
        "published stable runtime does not match the current runtime payload; "
        "wait for Publish Worker Runtime to finish"
    )
PYTHON

printf '%s\n' "$expected_version"
