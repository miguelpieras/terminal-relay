#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
server_directory="$repository_root/Server"
payload_list="$server_directory/worker-runtime-files.txt"
runtime_version="${1:-}"
output_path="${2:-}"

[[ "$runtime_version" =~ ^[1-9][0-9]*$ && "$output_path" == /* ]] || {
    echo "Usage: $0 RUNTIME_VERSION OUTPUT_PATH" >&2
    exit 64
}

/usr/bin/python3 - "$server_directory" "$payload_list" "$runtime_version" "$output_path" <<'PYTHON'
import hashlib
import json
import pathlib
import sys

server = pathlib.Path(sys.argv[1]).resolve()
payload_list = pathlib.Path(sys.argv[2])
version = int(sys.argv[3])
output = pathlib.Path(sys.argv[4])
files = []
for raw_line in payload_list.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    source_name, destination, mode = line.split("|")
    source = server / source_name
    if not source.is_file() or source.is_symlink():
        raise SystemExit(f"missing runtime payload: {source_name}")
    files.append(
        {
            "source": source_name,
            "destination": destination,
            "mode": mode,
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        }
    )
manifest = {
    "schemaVersion": 1,
    "channel": "operator",
    "runtimeVersion": version,
    "releaseVersion": "development",
    "protocol": {"minimum": 1, "maximum": 2},
    "capabilities": [
        "agent-sessions",
        "chat-v1",
        "file-attachments-v1",
        "runtime-updates-v1",
        "threads-v1",
        "threads-v2",
    ],
    "files": files,
}
output.write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PYTHON
