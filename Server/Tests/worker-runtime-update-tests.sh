#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test_directory="$(mktemp -d "$temporary_root/terminal-relay-runtime-tests.XXXXXX")"

cleanup() {
    exit_code=$?
    trap - EXIT
    case "$test_directory" in
        "$temporary_root"/terminal-relay-runtime-tests.*)
            /bin/rm -rf -- "$test_directory"
            ;;
        *) exit_code=1 ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT

openssl_bin="${OPENSSL_BIN:-$(command -v openssl)}"
"$openssl_bin" genpkey -algorithm ED25519 -out "$test_directory/private.pem" >/dev/null 2>&1
"$openssl_bin" pkey -in "$test_directory/private.pem" -pubout \
    -out "$test_directory/public.pem" >/dev/null 2>&1

WORKER_RUNTIME_SIGNING_KEY_PATH="$test_directory/private.pem" \
WORKER_RUNTIME_PUBLIC_KEY_PATH="$test_directory/public.pem" \
OPENSSL_BIN="$openssl_bin" \
    "$repository_root/Scripts/build-worker-runtime.sh" \
        2000000000 \
        1.0.0 \
        "$test_directory/release"

"$openssl_bin" pkeyutl \
    -verify \
    -pubin \
    -inkey "$test_directory/public.pem" \
    -rawin \
    -in "$test_directory/release/manifest.json" \
    -sigfile "$test_directory/release/manifest.sig" >/dev/null

/usr/bin/python3 - \
    "$repository_root/Server" \
    "$test_directory/release/manifest.json" \
    "$test_directory/release/runtime.tar.gz" <<'PYTHON'
import hashlib
import json
import pathlib
import sys
import tarfile

server = pathlib.Path(sys.argv[1])
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
archive_path = pathlib.Path(sys.argv[3])
assert manifest["schemaVersion"] == 1
assert manifest["channel"] == "stable"
assert manifest["runtimeVersion"] == 2_000_000_000
assert manifest["releaseVersion"] == "1.0.0"
assert manifest["protocol"] == {"minimum": 1, "maximum": 2}
assert manifest["capabilities"] == [
    "agent-sessions",
    "chat-v1",
    "chat-v2",
    "file-attachments-v1",
    "provider-accounts-v1",
    "runtime-updates-v1",
    "threads-v1",
    "threads-v2",
    "threads-v3",
]
assert hashlib.sha256(archive_path.read_bytes()).hexdigest() == manifest["archiveSHA256"]
expected = {item["source"]: item for item in manifest["files"]}
with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    assert {member.name for member in members} == set(expected)
    for member in members:
        item = expected[member.name]
        assert member.isreg()
        assert member.uid == 0 and member.gid == 0
        assert member.mode == int(item["mode"], 8)
        contents = archive.extractfile(member).read()
        assert hashlib.sha256(contents).hexdigest() == item["sha256"]
        assert hashlib.sha256((server / member.name).read_bytes()).hexdigest() == item["sha256"]
PYTHON

/bin/cp "$test_directory/release/manifest.json" "$test_directory/tampered.json"
printf ' ' >> "$test_directory/tampered.json"
if "$openssl_bin" pkeyutl \
    -verify \
    -pubin \
    -inkey "$test_directory/public.pem" \
    -rawin \
    -in "$test_directory/tampered.json" \
    -sigfile "$test_directory/release/manifest.sig" >/dev/null 2>&1; then
    echo "Tampered worker runtime manifest unexpectedly verified." >&2
    exit 1
fi

"$repository_root/Scripts/write-installed-runtime-manifest.sh" \
    2000000001 \
    "$test_directory/installed.json"
/usr/bin/python3 - "$test_directory/installed.json" <<'PYTHON'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["channel"] == "operator"
assert manifest["runtimeVersion"] == 2_000_000_001
assert manifest["protocol"] == {"minimum": 1, "maximum": 2}
assert len(manifest["files"]) >= 10
PYTHON

if ! /usr/bin/grep -Eq \
    '^ReadWritePaths=.*(^| )/usr/local/libexec( |$)' \
    "$repository_root/Server/terminal-relay-runtime-update.service"; then
    echo "The runtime updater cannot install its command gateway payload." >&2
    exit 1
fi

echo "Worker runtime update tests passed."
