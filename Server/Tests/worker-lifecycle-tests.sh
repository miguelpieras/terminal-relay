#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
baseline="$repository_root/Server/worker-baseline.example.env"
local_baseline="$repository_root/Server/worker-baseline.local.env"
host_installer="$repository_root/Server/install-worker-host.sh"
application_installer="$repository_root/Server/install-worker.sh"
session_helper="$repository_root/Server/terminal-relay-session"
agent_updater="$repository_root/Server/terminal-relay-agent-update"
lifecycle="$repository_root/Scripts/manage-worker.sh"
review_lifecycle="$repository_root/Scripts/manage-review-worker.sh"
review_tests="$repository_root/Server/Tests/review-worker-tests.sh"
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
    "$review_lifecycle" \
    "$review_tests" \
    "$bootstrap"; do
    [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe lifecycle file: $file"
done
[[ -x "$host_installer" && -x "$lifecycle" && -x "$review_lifecycle" \
    && -x "$review_tests" && -x "$bootstrap" ]] \
    || fail "lifecycle commands are not executable"

# shellcheck disable=SC1090
. "$baseline"
[[ "$TERMINAL_RELAY_BASELINE_VERSION" == terminal-relay-host-v1 ]]
[[ "$TERMINAL_RELAY_PROVIDER_PROJECT_ID" == REPLACE_ME ]]
[[ "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" == REPLACE_ME ]]
[[ "$TERMINAL_RELAY_SERVER_TYPE" == cpx22 ]]
[[ "$TERMINAL_RELAY_SERVER_LOCATION" == fsn1 ]]
[[ "$TERMINAL_RELAY_SERVER_IMAGE" == ubuntu-24.04 ]]
[[ "$TERMINAL_RELAY_TAILSCALE_TAG" == tag:terminal-relay-worker ]]
[[ "$TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY" == REPLACE_ME ]]
[[ "$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT" == REPLACE_ME ]]
grep -Fxq 'Server/worker-baseline.local.env' "$repository_root/.gitignore" \
    || fail "local worker baseline is not ignored"
if [[ -f "$local_baseline" ]]; then
    git -C "$repository_root" ls-files --error-unmatch \
        Server/worker-baseline.local.env >/dev/null 2>&1 \
        && fail "local worker baseline is tracked"
    bash -n "$local_baseline"
fi

bash -n "$host_installer" "$lifecycle" "$bootstrap" \
    "$review_lifecycle" \
    "$application_installer" \
    "$agent_updater"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$host_installer" "$lifecycle" "$bootstrap" \
        "$review_lifecycle" \
        "$application_installer" \
        "$agent_updater"
fi

"$lifecycle" --help | grep -Fq './Scripts/manage-worker.sh provision 3' \
    || fail "lifecycle help is missing the one-command provisioning contract"
grep -Fq 'worker-baseline.env' "$bootstrap" \
    || fail "bootstrap does not include the shared baseline"
grep -Fq 'worker-baseline.local.env' "$bootstrap" \
    || fail "bootstrap does not load the ignored local baseline"
grep -Fq 'worker-baseline.local.env' "$lifecycle" \
    || fail "lifecycle does not load the ignored local baseline"
grep -Fq 'worker-baseline.env' "$application_installer" \
    || fail "application installer does not consume the shared baseline"
grep -Fq 'node-exporter.service.template' "$lifecycle" \
    || fail "lifecycle does not deploy the monitoring baseline"
grep -Fq 'terminal-relay-agent-update.timer' "$bootstrap" \
    || fail "bootstrap does not include automatic agent updates"
grep -Fq 'CODEX_NON_INTERACTIVE=1' "$agent_updater" \
    || fail "Codex automatic updates are not unattended"
grep -Fq 'apt/latest latest main' "$application_installer" \
    || fail "Claude automatic updates do not follow the latest signed channel"

for marker_source in "$application_installer" "$session_helper" "$agent_updater"; do
    grep -Fq 'codex-app-server-restart-required' "$marker_source" \
        || fail "$(basename "$marker_source") does not share the Codex restart marker"
done
grep -Fq '__schedule-codex-app-server-restart' "$application_installer" \
    || fail "application reconciliation does not schedule a Codex app-server restart"
grep -Fq '__schedule-codex-app-server-restart' "$agent_updater" \
    || fail "Codex updater does not schedule through the worker helper"
[[ "$(grep -Fc 'codex-app-server.lock' "$session_helper")" == "1" ]] \
    || fail "Codex restart scheduling and rotation do not use one worker lock path"
[[ "$(grep -Ec '^[[:space:]]+lock_codex_app_server' "$session_helper")" -ge "3" ]] \
    || fail "Codex scheduling, reservations, and RPCs do not share the worker lock"
/usr/bin/awk '
    /^    install_codex$/ { codex = NR }
    /^    install_runtime_files$/ { helper = NR }
    /^    schedule_codex_app_server_restart$/ { schedule = NR }
    END { exit !(codex && helper > codex && schedule > helper) }
' "$application_installer" \
    || fail "application reconciliation schedules Codex restart before its helper is installed"
grep -Fq '/usr/bin/sha256sum' "$agent_updater" \
    || fail "Codex updater does not detect no-op standalone updates"
/usr/bin/awk '
    /\/usr\/bin\/codex update; then/ { update = NR }
    /codex_fingerprint_after.*codex_fingerprint_before/ { changed = NR }
    /elif schedule_codex_app_server_restart; then/ { schedule = NR }
    END { exit !(update && changed > update && schedule > changed) }
' "$agent_updater" \
    || fail "Codex updater does not limit restart scheduling to changed binaries"
grep -Fq "PATH=\"\$safe_path\"" "$agent_updater" \
    || fail "Codex updater does not use the explicit worker PATH"

printf 'worker lifecycle tests passed\n'
"$review_tests"
