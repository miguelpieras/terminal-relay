#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
admin="$repository_root/Server/terminal-relay-review-admin"
enroll="$repository_root/Server/terminal-relay-review-enroll"
gateway="$repository_root/Server/terminal-relay-review-gateway"
lifecycle="$repository_root/Scripts/manage-review-worker.sh"
generator="$repository_root/Scripts/generate-review-pairing.swift"
payload_model="$repository_root/TerminalRelay/Models/MobilePairingPayload.swift"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_directory="$(mktemp -d "$temporary_root/terminal-relay-review-tests.XXXXXX")"

cleanup() {
    local exit_code=$?

    trap - EXIT
    if [[ "$(dirname "$temporary_directory")" == "$temporary_root" \
        && "$(basename "$temporary_directory")" == terminal-relay-review-tests.* ]]; then
        rm -rf -- "$temporary_directory"
    else
        printf 'Refusing to clean unexpected review test path.\n' >&2
        exit_code=1
    fi
    exit "$exit_code"
}
trap cleanup EXIT

fail() {
    printf 'review-worker-tests: %s\n' "$*" >&2
    exit 1
}

for file in "$admin" "$enroll" "$gateway" "$lifecycle" "$generator" "$payload_model"; do
    [[ -f "$file" && ! -L "$file" ]] || fail "missing review-worker file"
done

bash -n "$lifecycle"
python3 -c 'import pathlib; compile(pathlib.Path(__import__("sys").argv[1]).read_text(), __import__("sys").argv[1], "exec")' "$admin"
python3 -c 'import pathlib; compile(pathlib.Path(__import__("sys").argv[1]).read_text(), __import__("sys").argv[1], "exec")' "$enroll"
python3 -c 'import pathlib; compile(pathlib.Path(__import__("sys").argv[1]).read_text(), __import__("sys").argv[1], "exec")' "$gateway"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$lifecycle"
fi
"$lifecycle" --help | grep -Fq 'manage-review-worker.sh provision' \
    || fail "review lifecycle help is incomplete"

test_root="$temporary_directory/root"
runtime_home="$test_root/home/terminal-relay"
mkdir -p "$runtime_home/.ssh" "$test_root/root/.ssh" "$test_root/workspace"
chmod 0700 "$runtime_home/.ssh" "$test_root/root/.ssh"
operator_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOperatorExample terminal-relay-operator'
printf '%s\n' "$operator_key" > "$runtime_home/.ssh/authorized_keys"
printf '%s\n' "$operator_key" > "$test_root/root/.ssh/authorized_keys"
chmod 0600 "$runtime_home/.ssh/authorized_keys" "$test_root/root/.ssh/authorized_keys"

TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" configure
TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" seed
TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" verify >/dev/null
for repository in atlas launchpad northstar; do
    [[ -f "$test_root/workspace/$repository/.terminal-relay-review-fixture" ]] \
        || fail "review fixture was not seeded"
done

invitation_id='01234567-89ab-4def-8abc-0123456789ab'
expires_at=$(( $(date +%s) + 3600 ))
invitation_key='AAAAC3NzaC1lZDI1NTE5AAAAIReviewInvitationExample'
invitation_entry="restrict,command=\"/usr/local/bin/terminal-relay-review-enroll $invitation_id $expires_at 2\" ssh-ed25519 $invitation_key terminal-relay-review-invitation:$invitation_id"
printf '%s\n' "$invitation_entry" \
    | TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" install-invitation
grep -Fq "terminal-relay-review-invitation:$invitation_id" \
    "$runtime_home/.ssh/authorized_keys" \
    || fail "review invitation was not installed"

device_key_one="$(python3 -c 'import base64; print(base64.b64encode(b"a" * 40).decode())')"
device_line_one="ssh-ed25519 $device_key_one terminal-relay-ios"
encoded_device_one="$(printf '%s' "$device_line_one" | base64)"
SSH_ORIGINAL_COMMAND="terminal-relay-enroll-device $encoded_device_one" \
    HOME="$runtime_home" \
    "$enroll" "$invitation_id" "$expires_at" 2 >/dev/null
SSH_ORIGINAL_COMMAND="terminal-relay-enroll-device $encoded_device_one" \
    HOME="$runtime_home" \
    "$enroll" "$invitation_id" "$expires_at" 2 >/dev/null
[[ "$(grep -Fc "terminal-relay-review-device:$invitation_id:" \
    "$runtime_home/.ssh/authorized_keys")" == 1 ]] \
    || fail "review enrollment is not idempotent"
grep -Fq "terminal-relay-review-invitation:$invitation_id" \
    "$runtime_home/.ssh/authorized_keys" \
    || fail "reusable invitation was consumed"

device_key_two="$(python3 -c 'import base64; print(base64.b64encode(b"b" * 40).decode())')"
device_line_two="ssh-ed25519 $device_key_two terminal-relay-ios"
encoded_device_two="$(printf '%s' "$device_line_two" | base64)"
SSH_ORIGINAL_COMMAND="terminal-relay-enroll-device $encoded_device_two" \
    HOME="$runtime_home" \
    "$enroll" "$invitation_id" "$expires_at" 2 >/dev/null

device_key_three="$(python3 -c 'import base64; print(base64.b64encode(b"c" * 40).decode())')"
device_line_three="ssh-ed25519 $device_key_three terminal-relay-ios"
encoded_device_three="$(printf '%s' "$device_line_three" | base64)"
if SSH_ORIGINAL_COMMAND="terminal-relay-enroll-device $encoded_device_three" \
    HOME="$runtime_home" \
    "$enroll" "$invitation_id" "$expires_at" 2 >/dev/null 2>&1; then
    fail "review enrollment exceeded its device cap"
fi
if SSH_ORIGINAL_COMMAND="terminal-relay-enroll-device $encoded_device_three" \
    HOME="$runtime_home" \
    "$enroll" "$invitation_id" "$(( $(date +%s) - 1 ))" 2 >/dev/null 2>&1; then
    fail "expired review enrollment was accepted"
fi

TERMINAL_RELAY_REVIEW_GATEWAY_DRY_RUN=1 \
    SSH_ORIGINAL_COMMAND='/usr/local/bin/terminal-relay-session status' \
    "$gateway" \
    | grep -Fq 'terminal-relay-session' \
    || fail "review gateway rejected an app status command"
for review_command in \
    "/usr/local/bin/terminal-relay-session threads atlas active" \
    "/usr/local/bin/terminal-relay-session threads atlas archived next-page" \
    "/usr/local/bin/terminal-relay-session thread-create atlas" \
    "/usr/local/bin/terminal-relay-session thread-read atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" \
    "/usr/local/bin/terminal-relay-session thread-resume atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa --model gpt-5.6-sol --config 'model_reasoning_effort=\"max\"' --config 'tui.terminal_title=[\"thread-title\",\"run-state\"]' --dangerously-bypass-approvals-and-sandbox" \
    "/usr/local/bin/terminal-relay-session thread-rename atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 'Review task'" \
    "/usr/local/bin/terminal-relay-session thread-archive atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" \
    "/usr/local/bin/terminal-relay-session thread-unarchive atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" \
    "/usr/local/bin/terminal-relay-session threads-v2 claude atlas open" \
    "/usr/local/bin/terminal-relay-session threads-v2 codex atlas archived next-page" \
    "/usr/local/bin/terminal-relay-session thread-resume-v2 claude atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa --model fable --effort max --settings '{\"terminalProgressBarEnabled\":true}' --mcp-config '{\"mcpServers\":{\"terminal_relay\":{\"command\":\"/usr/local/bin/terminal-relay-mcp\"}}}' --strict-mcp-config --dangerously-skip-permissions" \
    "/usr/local/bin/terminal-relay-session thread-rename-v2 claude atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 'Review task'" \
    "/usr/local/bin/terminal-relay-session thread-archive-v2 claude atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" \
    "/usr/local/bin/terminal-relay-session thread-unarchive-v2 claude atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
do
    TERMINAL_RELAY_REVIEW_GATEWAY_DRY_RUN=1 \
        SSH_ORIGINAL_COMMAND="$review_command" \
        "$gateway" >/dev/null \
        || fail "review gateway rejected a typed thread command"
done
if TERMINAL_RELAY_REVIEW_GATEWAY_DRY_RUN=1 \
    SSH_ORIGINAL_COMMAND="/usr/local/bin/terminal-relay-session thread-rename atlas aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 'line
break'" \
    "$gateway" >/dev/null 2>&1; then
    fail "review gateway accepted a multiline thread name"
fi
if TERMINAL_RELAY_REVIEW_GATEWAY_DRY_RUN=1 \
    SSH_ORIGINAL_COMMAND='/bin/sh -lc whoami' \
    "$gateway" >/dev/null 2>&1; then
    fail "review gateway accepted a general shell command"
fi

printf 'changed\n' > "$test_root/workspace/atlas/NOTES.md"
TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" reset
grep -Fq 'Keep the sidebar compact.' "$test_root/workspace/atlas/NOTES.md" \
    || fail "review reset did not restore synthetic data"
if grep -Fq 'terminal-relay-review-device:' "$runtime_home/.ssh/authorized_keys"; then
    fail "review reset did not remove enrolled devices"
fi
grep -Fq "terminal-relay-review-invitation:$invitation_id" \
    "$runtime_home/.ssh/authorized_keys" \
    || fail "review reset removed the reusable invitation"
TERMINAL_RELAY_REVIEW_TEST_ROOT="$test_root" "$admin" revoke
if grep -Eq 'terminal-relay-review-(invitation|device):' \
    "$runtime_home/.ssh/authorized_keys"; then
    fail "review invitation revocation left review keys behind"
fi

xcrun swiftc "$payload_model" "$generator" \
    -o "$temporary_directory/generate-review-pairing"
"$temporary_directory/generate-review-pairing" \
    "App Review Worker" \
    "worker.example.com" \
    22 \
    terminal-relay \
    "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE" \
    "$expires_at" \
    8 \
    "$temporary_directory/generated-entry" \
    "$temporary_directory/generated-code"
grep -Fq 'terminal-relay-review-invitation:' "$temporary_directory/generated-entry" \
    || fail "review pairing generator omitted the restricted invitation"
grep -Fq 'terminal-relay://pair-device?' "$temporary_directory/generated-code" \
    || fail "review pairing generator did not create an app pairing code"

printf 'review worker tests passed\n'
