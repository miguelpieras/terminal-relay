#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
server_directory="$repository_root/Server"
payload_list="$server_directory/worker-runtime-files.txt"
runtime_version="${1:-}"
release_version="${2:-}"
output_directory="${3:-}"
signing_key="${WORKER_RUNTIME_SIGNING_KEY_PATH:-}"
verification_key="${WORKER_RUNTIME_PUBLIC_KEY_PATH:-$server_directory/terminal-relay-runtime-update.pub}"

usage() {
    echo "Usage: WORKER_RUNTIME_SIGNING_KEY_PATH=/path/to/key.pem $0 RUNTIME_VERSION RELEASE_VERSION OUTPUT_DIRECTORY" >&2
}

[[ "$runtime_version" =~ ^[1-9][0-9]*$ ]] || { usage; exit 64; }
[[ "$release_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { usage; exit 64; }
[[ "$output_directory" == /* ]] || { usage; exit 64; }
[[ -f "$signing_key" && ! -L "$signing_key" ]] || {
    echo "build-worker-runtime: WORKER_RUNTIME_SIGNING_KEY_PATH must name a regular Ed25519 private key" >&2
    exit 64
}
[[ -f "$payload_list" && ! -L "$payload_list" ]] || {
    echo "build-worker-runtime: missing canonical runtime payload list" >&2
    exit 66
}
[[ -f "$verification_key" && ! -L "$verification_key" ]] || {
    echo "build-worker-runtime: worker-runtime public key is unavailable" >&2
    exit 66
}

openssl_bin="${OPENSSL_BIN:-$(command -v openssl)}"
[[ -x "$openssl_bin" ]] || {
    echo "build-worker-runtime: OpenSSL is unavailable" >&2
    exit 69
}

/bin/mkdir -p "$output_directory"
manifest_path="$output_directory/manifest.json"
archive_path="$output_directory/runtime.tar.gz"
signature_path="$output_directory/manifest.sig"

/usr/bin/python3 - \
    "$server_directory" \
    "$payload_list" \
    "$runtime_version" \
    "$release_version" \
    "$archive_path" \
    "$manifest_path" <<'PYTHON'
import gzip
import hashlib
import io
import json
import pathlib
import sys
import tarfile

server = pathlib.Path(sys.argv[1]).resolve()
payload_list = pathlib.Path(sys.argv[2])
runtime_version = int(sys.argv[3])
release_version = sys.argv[4]
archive_path = pathlib.Path(sys.argv[5])
manifest_path = pathlib.Path(sys.argv[6])

entries = []
seen_sources = set()
seen_destinations = set()
for raw_line in payload_list.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("|")
    if len(parts) != 3:
        raise SystemExit("invalid canonical runtime payload entry")
    source_name, destination, mode_text = parts
    if (
        "/" in source_name
        or source_name in seen_sources
        or not destination.startswith("/")
        or destination in seen_destinations
        or mode_text not in {"0644", "0755"}
    ):
        raise SystemExit("unsafe canonical runtime payload entry")
    source = server / source_name
    if not source.is_file() or source.is_symlink():
        raise SystemExit(f"missing runtime payload: {source_name}")
    seen_sources.add(source_name)
    seen_destinations.add(destination)
    entries.append((source_name, destination, mode_text, source.read_bytes()))

archive_buffer = io.BytesIO()
with gzip.GzipFile(filename="", mode="wb", fileobj=archive_buffer, mtime=0) as gz:
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for source_name, _, mode_text, contents in entries:
            info = tarfile.TarInfo(source_name)
            info.size = len(contents)
            info.mode = int(mode_text, 8)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            archive.addfile(info, io.BytesIO(contents))

archive_contents = archive_buffer.getvalue()
archive_path.write_bytes(archive_contents)
manifest = {
    "schemaVersion": 1,
    "channel": "stable",
    "runtimeVersion": runtime_version,
    "releaseVersion": release_version,
    "protocol": {"minimum": 1, "maximum": 2},
    "capabilities": [
        "agent-sessions",
        "chat-v1",
        "file-attachments-v1",
        "runtime-updates-v1",
        "threads-v1",
        "threads-v2",
    ],
    "archiveURL": (
        "https://miguelpieras.github.io/terminal-relay/worker-runtime/"
        f"{runtime_version}/runtime.tar.gz"
    ),
    "archiveSHA256": hashlib.sha256(archive_contents).hexdigest(),
    "files": [
        {
            "source": source_name,
            "destination": destination,
            "mode": mode_text,
            "sha256": hashlib.sha256(contents).hexdigest(),
        }
        for source_name, destination, mode_text, contents in entries
    ],
}
manifest_path.write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PYTHON

"$openssl_bin" pkeyutl \
    -sign \
    -rawin \
    -inkey "$signing_key" \
    -in "$manifest_path" \
    -out "$signature_path"
"$openssl_bin" pkeyutl \
    -verify \
    -pubin \
    -inkey "$verification_key" \
    -rawin \
    -in "$manifest_path" \
    -sigfile "$signature_path" >/dev/null

echo "Created signed worker runtime $runtime_version in $output_directory"
