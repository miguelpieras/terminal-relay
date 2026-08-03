#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
test_directory="$(mktemp -d "$temporary_root/terminal-relay-pairing-tests.XXXXXX")"

cleanup() {
    local exit_code=$?
    trap - EXIT
    case "$test_directory" in
        "$temporary_root"/terminal-relay-pairing-tests.*) /bin/rm -rf -- "$test_directory" ;;
        *) exit_code=1 ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT

xcrun swiftc \
    "$repository_root/TerminalRelay/Models/MobilePairingPayload.swift" \
    "$repository_root/Scripts/generate-review-pairing.swift" \
    -o "$test_directory/generate-review-pairing"

expires_at=$(( $(date +%s) + 3600 ))
"$test_directory/generate-review-pairing" \
    "App Review Worker" \
    "worker.example.com" \
    22 \
    terminal-relay \
    "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE" \
    "$expires_at" \
    8 \
    "$test_directory/generated-entry" \
    "$test_directory/generated-code"

grep -Fq 'terminal-relay-review-invitation:' "$test_directory/generated-entry"
grep -Fq 'terminal-relay://pair-device?' "$test_directory/generated-code"

printf 'review pairing generator tests passed\n'
