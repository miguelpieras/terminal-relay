#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
version_command="$repository_root/Scripts/worker-runtime-version.sh"
preflight="$repository_root/Scripts/verify-published-worker-runtime.sh"
builder="$repository_root/Scripts/build-worker-runtime.sh"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test_directory="$(/usr/bin/mktemp -d "$temporary_root/terminal-relay-stable-preflight-tests.XXXXXX")"
openssl_bin="${OPENSSL_BIN:-$(command -v openssl)}"

cleanup() {
    local exit_code=$?

    trap - EXIT
    case "$test_directory" in
        "$temporary_root"/terminal-relay-stable-preflight-tests.*)
            /bin/rm -rf -- "$test_directory"
            ;;
        *) exit_code=1 ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT

"$openssl_bin" genpkey -algorithm ED25519 \
    -out "$test_directory/private.pem" >/dev/null 2>&1
"$openssl_bin" pkey -in "$test_directory/private.pem" -pubout \
    -out "$test_directory/public.pem"

runtime_version="$($version_command)"
WORKER_RUNTIME_SIGNING_KEY_PATH="$test_directory/private.pem" \
WORKER_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
OPENSSL_BIN="$openssl_bin" \
    "$builder" "$runtime_version" 1.0.0 "$test_directory/current"

actual_version="$(
    TERMINAL_RELAY_ALLOW_LOCAL_RUNTIME_FEED=1 \
    TERMINAL_RELAY_RUNTIME_FEED_ROOT="file://$test_directory/current" \
    TERMINAL_RELAY_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
    OPENSSL_BIN="$openssl_bin" \
        "$preflight"
)"
[[ "$actual_version" == "$runtime_version" ]] || {
    echo "Stable runtime preflight returned an unexpected version." >&2
    exit 1
}

stale_version=$((runtime_version - 1))
WORKER_RUNTIME_SIGNING_KEY_PATH="$test_directory/private.pem" \
WORKER_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
OPENSSL_BIN="$openssl_bin" \
    "$builder" "$stale_version" 1.0.0 "$test_directory/stale"
if TERMINAL_RELAY_ALLOW_LOCAL_RUNTIME_FEED=1 \
    TERMINAL_RELAY_RUNTIME_FEED_ROOT="file://$test_directory/stale" \
    TERMINAL_RELAY_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
    OPENSSL_BIN="$openssl_bin" \
        "$preflight" >/dev/null 2>&1; then
    echo "Stable runtime preflight accepted a stale signed feed." >&2
    exit 1
fi

/bin/cp -R "$test_directory/current" "$test_directory/mismatched"
/usr/bin/python3 - "$test_directory/mismatched/manifest.json" <<'PYTHON'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["files"][0]["sha256"] = "0" * 64
path.write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PYTHON
"$openssl_bin" pkeyutl \
    -sign \
    -rawin \
    -inkey "$test_directory/private.pem" \
    -in "$test_directory/mismatched/manifest.json" \
    -out "$test_directory/mismatched/manifest.sig"
if TERMINAL_RELAY_ALLOW_LOCAL_RUNTIME_FEED=1 \
    TERMINAL_RELAY_RUNTIME_FEED_ROOT="file://$test_directory/mismatched" \
    TERMINAL_RELAY_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
    OPENSSL_BIN="$openssl_bin" \
        "$preflight" >/dev/null 2>&1; then
    echo "Stable runtime preflight accepted mismatched payload digests." >&2
    exit 1
fi

/usr/bin/python3 - "$test_directory/current/manifest.sig" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
contents = bytearray(path.read_bytes())
contents[0] ^= 1
path.write_bytes(contents)
PYTHON
if TERMINAL_RELAY_ALLOW_LOCAL_RUNTIME_FEED=1 \
    TERMINAL_RELAY_RUNTIME_FEED_ROOT="file://$test_directory/current" \
    TERMINAL_RELAY_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
    OPENSSL_BIN="$openssl_bin" \
        "$preflight" >/dev/null 2>&1; then
    echo "Stable runtime preflight accepted an invalid signature." >&2
    exit 1
fi

echo "Stable runtime preflight tests passed."
