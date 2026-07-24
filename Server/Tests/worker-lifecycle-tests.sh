#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
baseline="$repository_root/Server/worker-baseline.env"
host_installer="$repository_root/Server/install-worker-host.sh"
lifecycle="$repository_root/Scripts/manage-worker.sh"
bootstrap="$repository_root/Scripts/bootstrap-worker.sh"
temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
temporary_directory="$(mktemp -d "$temporary_root/terminal-relay-lifecycle-tests.XXXXXX")"

cleanup() {
    local exit_code=$?

    trap - EXIT
    if [[ "$(dirname "$temporary_directory")" == "$temporary_root" \
        && "$(basename "$temporary_directory")" == terminal-relay-lifecycle-tests.* ]]; then
            rm -rf -- "$temporary_directory"
    else
        printf 'Refusing to clean unexpected test path: %s\n' "$temporary_directory" >&2
        exit_code=1
    fi
    exit "$exit_code"
}
trap cleanup EXIT

fail() {
    printf 'worker-lifecycle-tests: %s\n' "$*" >&2
    exit 1
}

for file in \
    "$baseline" \
    "$host_installer" \
    "$repository_root/Server/node-exporter.service.template" \
    "$lifecycle" \
    "$bootstrap"; do
    [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe lifecycle file: $file"
done
[[ -x "$host_installer" && -x "$lifecycle" && -x "$bootstrap" ]] \
    || fail "lifecycle commands are not executable"

# shellcheck disable=SC1090
. "$baseline"
[[ "$TERMINAL_RELAY_BASELINE_VERSION" == terminal-relay-host-v1 ]]
[[ "$TERMINAL_RELAY_PROVIDER_PROJECT_ID" == 1234567 ]]
[[ "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" == 7654321 ]]
[[ "$TERMINAL_RELAY_SERVER_TYPE" == cpx22 ]]
[[ "$TERMINAL_RELAY_SERVER_LOCATION" == fsn1 ]]
[[ "$TERMINAL_RELAY_SERVER_IMAGE" == ubuntu-24.04 ]]
[[ "$TERMINAL_RELAY_TAILSCALE_TAG" == tag:terminal-relay-worker ]]
printf '%s\n' "$TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY" \
    > "$temporary_directory/operator.pub"
actual_fingerprint="$(ssh-keygen -lf "$temporary_directory/operator.pub" -E sha256 \
    | awk 'NR == 1 { print $2 }')"
[[ "$actual_fingerprint" == "$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT" ]] \
    || fail "baseline operator public key and fingerprint disagree"

bash -n "$host_installer" "$lifecycle" "$bootstrap" \
    "$repository_root/Server/install-worker.sh" \
    "$repository_root/Server/terminal-relay-agent-update"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$host_installer" "$lifecycle" "$bootstrap" \
        "$repository_root/Server/install-worker.sh" \
        "$repository_root/Server/terminal-relay-agent-update"
fi

"$lifecycle" --help | grep -Fq './Scripts/manage-worker.sh provision 3' \
    || fail "lifecycle help is missing the one-command provisioning contract"
grep -Fq 'worker-baseline.env' "$bootstrap" \
    || fail "bootstrap does not include the shared baseline"
grep -Fq 'worker-baseline.env' "$repository_root/Server/install-worker.sh" \
    || fail "application installer does not consume the shared baseline"
grep -Fq 'node-exporter.service.template' "$lifecycle" \
    || fail "lifecycle does not deploy the monitoring baseline"
grep -Fq 'terminal-relay-agent-update.timer' "$bootstrap" \
    || fail "bootstrap does not include automatic agent updates"
grep -Fq 'CODEX_NON_INTERACTIVE=1' "$repository_root/Server/terminal-relay-agent-update" \
    || fail "Codex automatic updates are not unattended"
grep -Fq 'apt/latest latest main' "$repository_root/Server/install-worker.sh" \
    || fail "Claude automatic updates do not follow the latest signed channel"

printf 'worker lifecycle tests passed\n'
