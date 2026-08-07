#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
baseline="$repository_root/Server/worker-baseline.example.env"
local_baseline="$repository_root/Server/worker-baseline.local.env"
host_installer="$repository_root/Server/install-worker-host.sh"
security_metrics_collector="$repository_root/Server/terminal-relay-security-metrics"
security_metrics_service="$repository_root/Server/terminal-relay-security-metrics.service"
security_metrics_timer="$repository_root/Server/terminal-relay-security-metrics.timer"
application_installer="$repository_root/Server/install-worker.sh"
session_helper="$repository_root/Server/terminal-relay-session"
agent_updater="$repository_root/Server/terminal-relay-agent-update"
lifecycle="$repository_root/Scripts/manage-worker.sh"
review_lifecycle="$repository_root/Scripts/manage-review-worker.sh"
review_tests="$repository_root/Server/Tests/review-worker-tests.sh"
bootstrap="$repository_root/Scripts/bootstrap-worker.sh"
helper_installer="$repository_root/Scripts/install-worker-session-helper.sh"
runtime_payload="$repository_root/Server/worker-runtime-files.txt"
runtime_version="$repository_root/Scripts/worker-runtime-version.sh"
stable_runtime_preflight="$repository_root/Scripts/verify-published-worker-runtime.sh"
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
    "$security_metrics_collector" \
    "$security_metrics_service" \
    "$security_metrics_timer" \
    "$lifecycle" \
    "$review_lifecycle" \
    "$review_tests" \
    "$runtime_payload" \
    "$runtime_version" \
    "$stable_runtime_preflight" \
    "$helper_installer" \
    "$bootstrap"; do
    [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe lifecycle file: $file"
done
[[ -x "$host_installer" && -x "$security_metrics_collector" \
    && -x "$lifecycle" && -x "$review_lifecycle" \
    && -x "$review_tests" && -x "$runtime_version" \
    && -x "$stable_runtime_preflight" && -x "$helper_installer" \
    && -x "$bootstrap" ]] \
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
[[ "$TERMINAL_RELAY_TAILSCALE_VERSION" == 1.102.2 ]]
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

bash -n "$host_installer" "$security_metrics_collector" "$lifecycle" "$bootstrap" \
    "$runtime_version" "$stable_runtime_preflight" \
    "$review_lifecycle" \
    "$application_installer" \
    "$agent_updater"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$host_installer" "$security_metrics_collector" "$lifecycle" "$bootstrap" \
        "$runtime_version" "$stable_runtime_preflight" \
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
for security_metrics_file in \
    terminal-relay-security-metrics \
    terminal-relay-security-metrics.service \
    terminal-relay-security-metrics.timer; do
    grep -Fq "$security_metrics_file" "$lifecycle" \
        || fail "lifecycle does not bundle $security_metrics_file"
    grep -Fq "$security_metrics_file" "$host_installer" \
        || fail "host installer does not install or verify $security_metrics_file"
done
grep -Fq 'minimum_tailscale_version="1.102.1"' "$security_metrics_collector" \
    || fail "security metrics use the wrong Tailscale security minimum"
grep -Fq '/var/lib/prometheus/node-exporter' "$security_metrics_collector" \
    || fail "security metrics use the wrong node-exporter directory"
grep -Fq 'fleet-security.prom' "$security_metrics_collector" \
    || fail "security metrics use the wrong node-exporter textfile"
for metric in \
    fleet_tailscale_version_info \
    fleet_tailscale_security_update_required \
    fleet_tailscale_auto_update_enabled \
    fleet_reboot_required; do
    grep -Fq "$metric" "$security_metrics_collector" \
        || fail "security collector does not publish $metric"
done

metrics_test_directory="$temporary_directory/security-metrics"
fake_tailscale="$temporary_directory/fake-tailscale"
/bin/mkdir -m 0755 "$metrics_test_directory"
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'case "$*" in'
    printf '%s\n' '    version) printf '\''%s\n'\'' "${FAKE_TAILSCALE_VERSION:-1.102.2}" ;;'
    printf '%s\n' '    "debug prefs") printf '\''{"AutoUpdate":{"Apply":%s}}\n'\'' "${FAKE_TAILSCALE_AUTO_UPDATE:-true}" ;;'
    printf '%s\n' '    *) exit 2 ;;'
    printf '%s\n' 'esac'
} > "$fake_tailscale"
/bin/chmod 0755 "$fake_tailscale"
: > "$temporary_directory/reboot-required"
TERMINAL_RELAY_SECURITY_METRICS_DIRECTORY="$metrics_test_directory" \
TERMINAL_RELAY_SECURITY_METRICS_REBOOT_REQUIRED_FILE="$temporary_directory/reboot-required" \
TERMINAL_RELAY_SECURITY_METRICS_TAILSCALE_COMMAND="$fake_tailscale" \
    "$security_metrics_collector"
grep -Fqx 'fleet_tailscale_version_info{version="1.102.2"} 1' \
    "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector does not report the current Tailscale version"
grep -Fqx 'fleet_tailscale_security_update_required 0' \
    "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector rejects a Tailscale version above the minimum"
grep -Fqx 'fleet_tailscale_auto_update_enabled 1' \
    "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector does not report enabled Tailscale auto-updates"
grep -Fqx 'fleet_reboot_required 1' "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector does not report a required reboot"

/bin/rm -f -- "$temporary_directory/reboot-required"
FAKE_TAILSCALE_VERSION=1.102.0 \
FAKE_TAILSCALE_AUTO_UPDATE=false \
TERMINAL_RELAY_SECURITY_METRICS_DIRECTORY="$metrics_test_directory" \
TERMINAL_RELAY_SECURITY_METRICS_REBOOT_REQUIRED_FILE="$temporary_directory/reboot-required" \
TERMINAL_RELAY_SECURITY_METRICS_TAILSCALE_COMMAND="$fake_tailscale" \
    "$security_metrics_collector"
grep -Fqx 'fleet_tailscale_security_update_required 1' \
    "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector accepts a Tailscale version below the minimum"
grep -Fqx 'fleet_tailscale_auto_update_enabled 0' \
    "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector does not report disabled Tailscale auto-updates"
grep -Fqx 'fleet_reboot_required 0' "$metrics_test_directory/fleet-security.prom" \
    || fail "security collector reports a reboot without the reboot marker"
grep -Fq 'terminal-relay-agent-update.timer' "$runtime_payload" \
    || fail "bootstrap does not include automatic agent updates"
grep -Fq 'terminal-relay-claude-sessions' "$runtime_payload" \
    || fail "bootstrap does not include the Claude session adapter"
grep -Fq 'claude-agent-sdk-requirements.txt' "$runtime_payload" \
    || fail "bootstrap does not include the pinned Claude session SDK requirements"
grep -Fq '"${runtime_payload_paths[@]}"' "$bootstrap" \
    || fail "bootstrap validation and archive creation do not share one payload list"
grep -Fq 'terminal-relay-runtime-update.timer' "$runtime_payload" \
    || fail "bootstrap does not include automatic runtime updates"
grep -Fq 'worker-runtime-files.txt' "$bootstrap" \
    || fail "bootstrap does not consume the canonical runtime payload list"
grep -Fq 'verify-published-worker-runtime.sh' "$bootstrap" \
    || fail "bootstrap does not require the matching signed stable runtime"
grep -Fq 'verify-published-worker-runtime.sh' "$lifecycle" \
    || fail "fleet verification does not require the matching signed stable runtime"
grep -Fq 'verify-published-worker-runtime.sh' "$review_lifecycle" \
    || fail "App Review provisioning does not require the matching signed stable runtime"
grep -Fq 'verify-published-worker-runtime.sh' "$helper_installer" \
    || fail "helper-only installation does not require the matching signed stable runtime"
grep -Fq 'CODEX_NON_INTERACTIVE=1' "$agent_updater" \
    || fail "Codex automatic updates are not unattended"
grep -Fq 'apt/latest latest main' "$application_installer" \
    || fail "Claude automatic updates do not follow the latest signed channel"
grep -Eq '^[[:space:]]+bubblewrap[[:space:]]+\\$' "$application_installer" \
    || fail "application installer does not provision the bubblewrap package"
grep -Fq 'SESSION_HELPER_SOURCE="$SERVER_DIRECTORY/terminal-relay-session"' "$lifecycle" \
    || fail "fleet verification does not fingerprint the repository session helper"
grep -Fq 'sha256sum "$session_helper"' "$lifecycle" \
    || fail "fleet verification does not compare the deployed session helper"
grep -Fq 'expected_helper_digest="$1"' "$lifecycle" \
    || fail "fleet verification does not pass the expected helper digest remotely"
grep -Fq '= "$expected_helper_digest"' "$lifecycle" \
    || fail "fleet verification does not require the deployed helper digest to match"

for bubblewrap_source in "$application_installer" "$lifecycle"; do
    grep -Fq 'command -v bwrap' "$bubblewrap_source" \
        || fail "$(basename "$bubblewrap_source") does not resolve bubblewrap through PATH"
    /usr/bin/awk '
        /\/usr\/bin\/bwrap[[:space:]]*\\$/ { probe = NR }
        probe && NR > probe && NR <= probe + 4 && /--unshare-user/ { user = NR }
        probe && NR > probe && NR <= probe + 4 && /--unshare-net/ { network = NR }
        probe && NR > probe && NR <= probe + 5 && /--ro-bind \/ \// { bind = NR }
        END { exit !(probe && user > probe && network > user && bind > network) }
    ' "$bubblewrap_source" \
        || fail "$(basename "$bubblewrap_source") does not run the full bubblewrap namespace probe"
done

for marker_source in "$application_installer" "$session_helper" "$agent_updater"; do
    grep -Fq 'codex-app-server-restart-required' "$marker_source" \
        || fail "$(basename "$marker_source") does not share the Codex restart marker"
done
grep -Fq 'codex-app-server-restart-required' "$lifecycle" \
    || fail "fleet verification does not inspect a pending Codex app-server restart"
grep -Fq '"$session_helper" __schedule-codex-app-server-restart' "$lifecycle" \
    || fail "fleet verification does not schedule an unsafe Codex app-server rotation"
grep -Fq '"$session_helper" __verify-codex-account >/dev/null' "$lifecycle" \
    || fail "fleet verification does not require the shared Codex account after rotation"
grep -Fq 'stat -c '\''%U:%G:%a'\'' "$codex_restart_marker"' "$lifecycle" \
    || fail "fleet verification does not require a secure deferred restart marker"
grep -Fq '$1 == "session" && $2 == "codex"' "$lifecycle" \
    || fail "fleet verification does not limit deferred restarts to active Codex terminals"
grep -Fq '[[ "$active_codex_terminals" =~ ^[1-9][0-9]*$ ]]' "$lifecycle" \
    || fail "fleet verification does not require an active Codex terminal for deferral"
grep -Fq 'run_codex_rpc_with_app_server_lock require-account' "$session_helper" \
    || fail "worker helper does not expose fail-closed shared Codex account verification"
[[ "$(grep -Fc '/usr/local/bin/terminal-relay-session __verify-codex-account' "$bootstrap")" -eq 2 ]] \
    || fail "worker bootstrap does not verify the shared Codex account before and after login"
grep -Fq '/usr/local/bin/terminal-relay-session codex-login' "$bootstrap" \
    || fail "worker bootstrap does not authenticate through the shared Codex app-server"
if grep -Fq '/usr/bin/codex login' "$bootstrap"; then
    fail "worker bootstrap bypasses the shared Codex app-server during authentication"
fi
grep -Fq 'test ! -L "$codex_restart_marker"' "$lifecycle" \
    || fail "fleet verification does not reject a symlinked Codex restart marker"
grep -Fq "'#{pane_pid}'" "$lifecycle" \
    || fail "fleet verification does not resolve the live Codex app-server pid through tmux"
grep -Fq '"/proc/$app_server_pid/environ"' "$lifecycle" \
    || fail "fleet verification does not read the live Codex app-server environment"
grep -Fq 'test "$app_server_path" = "$safe_path"' "$lifecycle" \
    || fail "fleet verification does not inspect the live Codex app-server PATH"
grep -Fq 'local -a numbers=()' "$lifecycle" \
    || fail "fleet-wide lifecycle actions do not snapshot every configured worker number"
grep -Fq 'for number in "${numbers[@]}"' "$lifecycle" \
    || fail "fleet-wide lifecycle actions can let SSH consume undispatched workers"
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
