#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
installer="$repository_root/Scripts/install-worker-session-helper.sh"
restore_unit="$repository_root/Server/terminal-relay-session-restore@.service"
# Used by build_locked_remote_command loaded from the installer below.
# shellcheck disable=SC2034
remote_lock_path="/run/lock/terminal-relay-session-helper.lock"

[[ -f "$installer" && ! -L "$installer" ]] \
    || { echo "Missing regular installer: $installer" >&2; exit 66; }
[[ -f "$restore_unit" && ! -L "$restore_unit" ]] \
    || { echo "Missing regular restore unit: $restore_unit" >&2; exit 66; }

# Load only the installer's command-rendering helpers; do not run its SSH path.
temporary_helpers="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/terminal-relay-renderers.XXXXXX")"
temporary_unit_directory=""
cleanup() {
    cleanup_status=$?
    trap - EXIT
    case "$temporary_helpers" in
        "${TMPDIR:-/tmp}"/terminal-relay-renderers.*) /bin/rm -f -- "$temporary_helpers" ;;
        *) echo "Refusing to remove unexpected renderer file: $temporary_helpers" >&2; cleanup_status=1 ;;
    esac
    if [[ -n "$temporary_unit_directory" ]]; then
        case "$temporary_unit_directory" in
            "${TMPDIR:-/tmp}"/terminal-relay-units.*) /bin/rm -rf -- "$temporary_unit_directory" ;;
            *) echo "Refusing to remove unexpected unit directory: $temporary_unit_directory" >&2; cleanup_status=1 ;;
        esac
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT
/usr/bin/awk '
    /^quote_remote\(\)/ { copying = 1 }
    /^validate_ssh_target / { copying = 0 }
    /^render_runtime_control_script\(\)/ { copying = 1 }
    /^runtime_control_script=/ { copying = 0 }
    copying { print }
' "$installer" > "$temporary_helpers"
# shellcheck disable=SC1090
source "$temporary_helpers"

install_script="$(/usr/bin/sed -n "/<<'REMOTE_INSTALL'/,/^REMOTE_INSTALL$/p" "$installer" \
    | /usr/bin/sed '1d;$d')"
rollback_script="$(/usr/bin/sed -n "/<<'REMOTE_ROLLBACK'/,/^REMOTE_ROLLBACK$/p" "$installer" \
    | /usr/bin/sed '1d;$d')"
runtime_control_script="$(render_runtime_control_script)"

# shellcheck disable=SC2016
[[ "$install_script" == *'case "$helper_staged" in'* \
    && "$install_script" == *'"$helper_installed_digest"'* \
    && "$install_script" == *'"$unit_installed_digest"'* \
    && "$install_script" == *'"$service_initial_enabled"'* \
    && "$install_script" == *'"$claude_sdk_current/bin/python3"'* \
    && "$install_script" == *'"$claude_sessions_target" version'* \
    && "$install_script" == *'claude-agent-sdk-requirements.txt'* \
    && "$install_script" == *'chmod -R a+rX,u+w,go-w "$claude_sdk_environment"'* \
    && "$install_script" == *'systemctl daemon-reload'* \
    && "$install_script" == *'systemctl enable "$service"'* \
    && "$install_script" == *'"$helper_target" __schedule-codex-app-server-restart'* \
    && "$install_script" == *'codex-app-server-restart-required'* ]] \
    || { echo "Install renderer expanded or lost literal remote variables." >&2; exit 1; }
# shellcheck disable=SC2016
[[ "$rollback_script" == *'case "$helper_staged" in'* \
    && "$rollback_script" == *'"$expected_helper_digest"'* \
    && "$rollback_script" == *'"$expected_unit_digest"'* \
    && "$rollback_script" == *'"$service_initial_active"'* \
    && "$rollback_script" == *'systemctl daemon-reload'* ]] \
    || { echo "Rollback renderer expanded or lost literal remote variables." >&2; exit 1; }
# shellcheck disable=SC2016
[[ "$runtime_control_script" == *'temporary_directory="$(/usr/bin/mktemp -d '* \
    && "$runtime_control_script" == *'case "$temporary_directory" in'* \
    && "$runtime_control_script" == *'"$temporary_directory/runtime-manifest.json"'* \
    && "$runtime_control_script" == *'systemctl enable --now'* ]] \
    || { echo "Runtime-control renderer expanded or lost literal remote variables." >&2; exit 1; }
[[ "$(< "$installer")" == *"runtime|\$runtime_version|1|2|agent-sessions,chat-v1,file-attachments-v1,runtime-updates-v1,threads-v1,threads-v2"* ]] \
    || { echo "Helper installer does not verify the file-attachment runtime capability." >&2; exit 1; }
/bin/bash -n <<< "$runtime_control_script"
[[ "$(< "$restore_unit")" == *'ExecStart=/usr/local/bin/terminal-relay-session restore'* \
    && "$(< "$restore_unit")" == *'WantedBy=multi-user.target'* \
    && "$(< "$restore_unit")" == *'User=%i'* \
    && "$(< "$restore_unit")" != *'Environment=HOME='* ]] \
    || { echo "Restore unit is missing its managed restore lifecycle." >&2; exit 1; }

if command -v systemd-analyze >/dev/null 2>&1; then
    temporary_unit_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/terminal-relay-units.XXXXXX")"
    /usr/bin/sed \
        's|^ExecStart=/usr/local/bin/terminal-relay-session restore$|ExecStart=/bin/true|' \
        "$restore_unit" \
        > "$temporary_unit_directory/terminal-relay-session-restore@.service"
    systemd-analyze verify \
        "$temporary_unit_directory/terminal-relay-session-restore@.service"
fi

machine_id=00000000000000000000000000000000
host_name=terminal-relay-generation-test
digest=0000000000000000000000000000000000000000000000000000000000000000

for admin_uid in 0 1000; do
    install_command="$(build_locked_remote_command \
        "$admin_uid" "$install_script" terminal-relay-install \
        "$machine_id" "$host_name" terminal-relay false)"
    rollback_command="$(build_locked_remote_command \
        "$admin_uid" "$rollback_script" terminal-relay-rollback \
        "$machine_id" "$host_name" terminal-relay \
        "$digest" 1:2:3 new '' "$digest" 4:5:6 new '' false false)"
    validate_remote_rendering install "$install_script" "$install_command"
    validate_remote_rendering rollback "$rollback_script" "$rollback_command"
done

echo "PASS: worker helper remote command generation"
