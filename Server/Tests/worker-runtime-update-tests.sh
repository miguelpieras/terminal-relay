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

if ! /usr/bin/grep -Eq \
    '^ReadWritePaths=.*(^| )/home/terminal-relay/\.local/share/terminal-relay( |$)' \
    "$repository_root/Server/terminal-relay-runtime-update.service"; then
    echo "The updater sandbox blocks the provider account root the restart hook creates." >&2
    exit 1
fi

# Forward-compat contract: the validator judging a published manifest is
# always one release old, so TODAY'S validate_manifest must accept manifests
# shaped like plausible FUTURE releases (new capabilities, new files, new
# fields) while still rejecting writes outside the destination allowlist.
run_validate_manifest() {
    (
        set +e
        main() { :; }
        readonly -f main
        source "$repository_root/Server/terminal-relay-runtime-update" 2>/dev/null
        installed_version=1000000000
        validate_manifest "$1" "$2"
    )
}

/usr/bin/python3 - "$test_directory/release/manifest.json" "$test_directory" <<'PYTHON'
import copy
import json
import pathlib
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
out = pathlib.Path(sys.argv[2])
cases = []

def case(name, verdict, mutate):
    candidate = copy.deepcopy(manifest)
    mutate(candidate)
    (out / f"candidate-{name}.json").write_text(json.dumps(candidate))
    cases.append(f"{name}\t{verdict}")

new_file = {
    "source": "terminal-relay-new-tool",
    "destination": "/usr/local/bin/terminal-relay-new-tool",
    "mode": "0755",
    "sha256": "ab" * 32,
}

case("unchanged", "accept", lambda m: None)
case("new-capability", "accept",
     lambda m: m["capabilities"].append("workflows-v1"))
case("new-top-level-key", "accept",
     lambda m: m.update(minAppVersion="3.1"))
case("new-per-file-key", "accept",
     lambda m: m["files"][0].update(size=123))
case("wider-protocol", "accept",
     lambda m: m["protocol"].update(maximum=m["protocol"]["maximum"] + 1))
case("suffixed-release", "accept",
     lambda m: m.update(releaseVersion="1.2.3-rc1"))
case("build-metadata-release", "accept",
     lambda m: m.update(releaseVersion="1.4.0+build.1"))
case("added-file", "accept",
     lambda m: m["files"].append(new_file))
case("added-root-only-config", "accept",
     lambda m: m["files"].append(dict(
         new_file, destination="/etc/terminal-relay/future-policy.json",
         mode="0600")))
case("removed-file", "accept",
     lambda m: m["files"].remove(next(
         f for f in m["files"] if f["source"] == "terminal-relay-mobile-gateway")))

case("destination-outside-allowlist", "reject",
     lambda m: m["files"][0].update(destination="/etc/sudoers.d/evil"))
case("destination-outside-sdk-subtree", "reject",
     lambda m: m["files"][0].update(
         destination="/opt/terminal-relay/policies/gateway.json"))
case("destination-with-control-character", "reject",
     lambda m: m["files"][0].update(
         destination="/usr/local/bin/evil\tname"))
case("unsorted-capabilities", "reject",
     lambda m: m["capabilities"].insert(0, "zz-late-capability"))
case("destination-traversal", "reject",
     lambda m: m["files"][0].update(
         destination="/usr/local/bin/../../../etc/passwd"))
case("setuid-mode", "reject",
     lambda m: m["files"][0].update(mode="4755"))
case("source-with-slash", "reject",
     lambda m: m["files"].append(dict(new_file, source="../evil")))
case("duplicate-source", "reject",
     lambda m: m["files"].append(copy.deepcopy(m["files"][0])))
case("duplicate-destination", "reject",
     lambda m: m["files"].append(dict(
         new_file, destination=m["files"][0]["destination"])))
case("bad-digest", "reject",
     lambda m: m["files"][0].update(sha256="zz" * 32))
case("missing-updater-source", "reject",
     lambda m: m["files"].remove(next(
         f for f in m["files"] if f["source"] == "terminal-relay-runtime-update")))
case("empty-capabilities", "reject",
     lambda m: m.update(capabilities=[]))

(out / "forward-compat-cases.tsv").write_text("\n".join(cases) + "\n")
PYTHON

while IFS=$'\t' read -r case_name expected_verdict; do
    if run_validate_manifest \
        "$test_directory/candidate-$case_name.json" \
        "$test_directory/validated-$case_name.tsv"; then
        actual_verdict=accept
    else
        actual_verdict=reject
    fi
    if [[ "$actual_verdict" != "$expected_verdict" ]]; then
        echo "validate_manifest ${actual_verdict}ed the $case_name manifest;" \
            "expected $expected_verdict." >&2
        exit 1
    fi
done < "$test_directory/forward-compat-cases.tsv"

# The SDK version pin must come from the signed requirements file, and the
# derivation must work on the requirements file the runtime actually ships.
run_sdk_version_from_requirements() {
    (
        set +e
        main() { :; }
        readonly -f main
        source "$repository_root/Server/terminal-relay-runtime-update" 2>/dev/null
        sdk_version_from_requirements "$1"
    )
}

derived_sdk_version="$(run_sdk_version_from_requirements \
    "$repository_root/Server/claude-agent-sdk-requirements.txt")" || {
    echo "The shipped requirements file yields no claude-agent-sdk version." >&2
    exit 1
}
if [[ ! "$derived_sdk_version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
    echo "Derived SDK version is malformed: $derived_sdk_version" >&2
    exit 1
fi
printf 'httpx==0.28.1\n' > "$test_directory/requirements-without-sdk.txt"
if run_sdk_version_from_requirements \
    "$test_directory/requirements-without-sdk.txt" >/dev/null; then
    echo "A requirements file without a claude-agent-sdk pin was accepted." >&2
    exit 1
fi

# Every destination prefix the validator allows must be writable under the
# updater unit's sandbox, or a signed manifest can validate and then fail
# EROFS at install time on every retry.
/usr/bin/python3 - \
    "$repository_root/Server/terminal-relay-runtime-update" \
    "$repository_root/Server/terminal-relay-runtime-update.service" <<'PYTHON'
import re
import sys

updater = open(sys.argv[1], encoding="utf-8").read()
unit = open(sys.argv[2], encoding="utf-8").read()
prefixes = re.findall(r'^    "(/[^"]+/)",$', updater, re.MULTILINE)
assert prefixes, "no destination prefixes found in validate_manifest"
writable = []
for line in unit.splitlines():
    if line.startswith("ReadWritePaths="):
        writable = line.removeprefix("ReadWritePaths=").split()
assert writable, "no ReadWritePaths line found in the unit"
for prefix in prefixes:
    if not any(
        prefix == path or prefix.startswith(path.rstrip("/") + "/")
        for path in writable
    ):
        raise SystemExit(
            f"validator allows {prefix} but the unit sandbox cannot write it"
        )
PYTHON

echo "Worker runtime update tests passed."
