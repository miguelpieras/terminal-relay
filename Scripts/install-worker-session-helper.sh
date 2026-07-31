#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
source_helper="$repository_root/Server/terminal-relay-session"
source_chat="$repository_root/Server/terminal-relay-chat"
source_mcp="$repository_root/Server/terminal-relay-mcp"
source_claude_sessions="$repository_root/Server/terminal-relay-claude-sessions"
source_claude_requirements="$repository_root/Server/claude-agent-sdk-requirements.txt"
source_restore_unit="$repository_root/Server/terminal-relay-session-restore@.service"
stable_runtime_preflight="$script_directory/verify-published-worker-runtime.sh"
remote_lock_path="/run/lock/terminal-relay-session-helper.lock"

usage() {
    cat >&2 <<'EOF'
usage: install-worker-session-helper.sh [--retain-backups] application-ssh-target [admin-ssh-target]

The application target verifies the worker account, systemd, and /usr/bin/tmux.
The admin target must reach the same machine as root or as an account with
non-interactive sudo. The application target is required. If the admin target
is omitted, root@ is combined with the application target's host.
Managed files are replaced atomically without retained host copies by default.
Use --retain-backups only when a recoverable host-side rollback was requested.
EOF
}

retain_backups=false
if [[ "${1:-}" == "--retain-backups" ]]; then
    retain_backups=true
    shift
fi
[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 64; }
application_target="$1"
if [[ $# -eq 2 ]]; then
    admin_target="$2"
else
    admin_target="root@${application_target#*@}"
fi

validate_ssh_target() {
    local label="$1"
    local target="$2"
    if [[ -z "$target" || "$target" == -* || "$target" == *[[:space:]]* ]]; then
        echo "Invalid $label SSH target: $target" >&2
        exit 64
    fi
}

quote_remote() {
    printf '%s\n' "$1" | /usr/bin/sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

build_locked_remote_command() {
    local admin_uid="$1"
    local script="$2"
    local script_name="$3"
    local prefix
    local argument
    shift 3

    if [[ "$admin_uid" == "0" ]]; then
        prefix="/usr/bin/flock -x $(quote_remote "$remote_lock_path") /bin/bash -c"
    else
        prefix="sudo -n /usr/bin/flock -x $(quote_remote "$remote_lock_path") /bin/bash -c"
    fi
    printf '%s %s %s' "$prefix" "$(quote_remote "$script")" "$(quote_remote "$script_name")"
    for argument in "$@"; do
        printf ' %s' "$(quote_remote "$argument")"
    done
    printf '\n'
}

validate_remote_rendering() {
    local label="$1"
    local script="$2"
    local command="$3"

    printf '%s\n' "$script" | /bin/bash -n
    /bin/bash -n -c "$command"
    case "$label" in
        install)
            # These literals verify that remote-only variables survived rendering.
            # shellcheck disable=SC2016
            [[ "$script" == *'case "$helper_staged" in'* \
                && "$script" == *'"$helper_installed_digest"'* \
                && "$script" == *'"$unit_installed_digest"'* \
                && "$script" == *'"$service_initial_enabled"'* \
                && "$script" == *'"$claude_sdk_current/bin/python3"'* \
                && "$script" == *'"$claude_sessions_target" version'* \
                && "$script" == *'"$helper_target" __schedule-codex-app-server-restart'* ]] \
                || return 1
            ;;
        rollback)
            # shellcheck disable=SC2016
            [[ "$script" == *'case "$helper_staged" in'* \
                && "$script" == *'"$expected_helper_digest"'* \
                && "$script" == *'"$expected_unit_digest"'* \
                && "$script" == *'"$service_initial_active"'* ]] || return 1
            ;;
        *) return 64 ;;
    esac
}

validate_ssh_target "application" "$application_target"
validate_ssh_target "admin" "$admin_target"
[[ -f "$source_helper" && ! -L "$source_helper" ]] \
    || { echo "Missing regular worker helper source: $source_helper" >&2; exit 66; }
[[ -f "$source_restore_unit" && ! -L "$source_restore_unit" ]] \
    || { echo "Missing regular restore unit source: $source_restore_unit" >&2; exit 66; }
/bin/bash -n "$source_helper" \
    || { echo "Worker helper source failed Bash syntax validation." >&2; exit 65; }
[[ -f "$source_chat" && ! -L "$source_chat" ]] \
    || { echo "Missing regular structured chat broker source: $source_chat" >&2; exit 66; }
/usr/bin/python3 -c \
    'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
    "$source_chat" \
    || { echo "Structured chat broker failed Python syntax validation." >&2; exit 65; }
[[ -f "$source_mcp" && ! -L "$source_mcp" ]] \
    || { echo "Missing regular worker MCP source: $source_mcp" >&2; exit 66; }
[[ -f "$source_claude_sessions" && ! -L "$source_claude_sessions" ]] \
    || { echo "Missing regular Claude session adapter: $source_claude_sessions" >&2; exit 66; }
[[ -f "$source_claude_requirements" && ! -L "$source_claude_requirements" ]] \
    || { echo "Missing regular Claude SDK requirements: $source_claude_requirements" >&2; exit 66; }
/usr/bin/python3 -c \
    'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
    "$source_claude_sessions" \
    || { echo "Claude session adapter failed Python syntax validation." >&2; exit 65; }
runtime_version="$("$stable_runtime_preflight")" || {
    echo "Current runtime payload has not reached the signed stable feed." >&2
    exit 65
}

probe_target() {
    local target="$1"
    /usr/bin/ssh "$target" '
set -eu
machine_id=$(tr -d "\r\n" < /etc/machine-id)
host_name=$(hostname)
user_name=$(id -un)
user_id=$(id -u)
user_home=$(getent passwd "$user_id" | cut -d: -f6)
tmux_path=""
tmux_version=""
if [ -x /usr/bin/tmux ]; then
    tmux_path=/usr/bin/tmux
    tmux_version=$($tmux_path -V 2>/dev/null || true)
fi
flock_path=""
if [ -x /usr/bin/flock ]; then
    flock_path=/usr/bin/flock
fi
pidfd_support=no
if [ -x /usr/bin/python3 ] && /usr/bin/python3 - <<PYTHON_PIDFD_PROBE
import os
import signal

if not callable(getattr(os, "pidfd_open", None)):
    raise SystemExit(1)
if not callable(getattr(signal, "pidfd_send_signal", None)):
    raise SystemExit(1)
descriptor = os.pidfd_open(os.getpid(), 0)
os.close(descriptor)
PYTHON_PIDFD_PROBE
then
    pidfd_support=yes
fi
sudo_available=no
systemd_available=no
if [ -d /run/systemd/system ] && [ -x /usr/bin/systemctl ] && [ -x /usr/bin/systemd-analyze ]; then
    systemd_available=yes
fi
if [ "$user_id" = 0 ]; then
    sudo_available=root
elif command -v sudo >/dev/null 2>&1 && sudo -n /usr/bin/true >/dev/null 2>&1; then
    sudo_available=yes
fi
printf "%s\n" \
    "__TERMINAL_RELAY_WORKER_PROBE_V1__" \
    "machine|$machine_id" \
    "host|$host_name" \
    "user|$user_name" \
    "uid|$user_id" \
    "home|$user_home" \
    "tmux|$tmux_path" \
    "tmux-version|$tmux_version" \
    "flock|$flock_path" \
    "pidfd|$pidfd_support" \
    "systemd|$systemd_available" \
    "sudo|$sudo_available"
'
}

probe_field() {
    local probe="$1"
    local field="$2"
    printf '%s\n' "$probe" | /usr/bin/sed -n \
        "/^__TERMINAL_RELAY_WORKER_PROBE_V1__$/,/^sudo|/s/^$field|//p" | /usr/bin/tail -n 1
}

echo "Verifying application target: $application_target"
application_probe="$(probe_target "$application_target")"
application_machine="$(probe_field "$application_probe" machine)"
application_host="$(probe_field "$application_probe" host)"
application_user="$(probe_field "$application_probe" user)"
application_uid="$(probe_field "$application_probe" uid)"
application_home="$(probe_field "$application_probe" home)"
application_tmux="$(probe_field "$application_probe" tmux)"
application_tmux_version="$(probe_field "$application_probe" tmux-version)"
application_flock="$(probe_field "$application_probe" flock)"
application_pidfd="$(probe_field "$application_probe" pidfd)"
application_systemd="$(probe_field "$application_probe" systemd)"

if [[ ! "$application_machine" =~ ^[A-Fa-f0-9]{32}$ \
    || -z "$application_host" || "$application_host" == *$'\n'* \
    || ! "$application_user" =~ ^[a-z_][a-z0-9_-]*$ \
    || ! "$application_uid" =~ ^[0-9]+$ \
    || "$application_home" != /* || "$application_home" == *[[:space:]]* ]]; then
    echo "Application target returned an invalid worker identity." >&2
    exit 70
fi
if [[ "$application_tmux" != "/usr/bin/tmux" || -z "$application_tmux_version" ]]; then
    echo "/usr/bin/tmux is unavailable on application target $application_target." >&2
    exit 69
fi
if [[ "$application_flock" != "/usr/bin/flock" ]]; then
    echo "/usr/bin/flock is unavailable on application target $application_target." >&2
    exit 69
fi
if [[ "$application_pidfd" != "yes" ]]; then
    echo "/usr/bin/python3 with Linux pidfd signaling is unavailable on application target $application_target." >&2
    exit 69
fi
if [[ "$application_systemd" != "yes" ]]; then
    echo "systemd and systemd-analyze are unavailable on application target $application_target." >&2
    exit 69
fi
echo "Verified $application_user@$application_host (uid $application_uid, machine $application_machine)"
echo "Verified $application_tmux_version at $application_tmux"
echo "Verified /usr/bin/flock and /usr/bin/python3 Linux pidfd signaling"
echo "Verified systemd restore support for $application_user ($application_home)"

echo "Verifying admin target: $admin_target"
admin_probe="$(probe_target "$admin_target")"
admin_machine="$(probe_field "$admin_probe" machine)"
admin_host="$(probe_field "$admin_probe" host)"
admin_user="$(probe_field "$admin_probe" user)"
admin_uid="$(probe_field "$admin_probe" uid)"
admin_sudo="$(probe_field "$admin_probe" sudo)"

if [[ "$admin_machine" != "$application_machine" || "$admin_host" != "$application_host" ]]; then
    echo "Refusing to install: application and admin targets are different machines." >&2
    echo "Application: $application_host ($application_machine)" >&2
    echo "Admin: $admin_host ($admin_machine)" >&2
    exit 77
fi
if [[ "$admin_uid" != "0" && "$admin_sudo" != "yes" ]]; then
    echo "Admin target must be root or have non-interactive sudo: $admin_target" >&2
    exit 77
fi
echo "Verified admin account $admin_user@$admin_host (uid $admin_uid) on the same machine"

render_remote_install_script() {
    /bin/cat <<'REMOTE_INSTALL'
set -euo pipefail

expected_machine="$1"
expected_host="$2"
application_user="$3"
retain_backups="$4"
actual_machine=$(tr -d "\r\n" < /etc/machine-id)
actual_host=$(hostname)
if [ "$actual_machine" != "$expected_machine" ] || [ "$actual_host" != "$expected_host" ]; then
    echo "Refusing to install: worker identity changed inside the install connection." >&2
    exit 77
fi
case "$application_user" in
    ''|*[!a-z0-9_-]*|[0-9-]*)
        echo "Refusing to install for an invalid application user." >&2
        exit 77
        ;;
esac
case "$retain_backups" in
    true|false) ;;
    *) echo "Refusing to install with an invalid backup policy." >&2; exit 77 ;;
esac
/usr/bin/getent passwd "$application_user" >/dev/null \
    || { echo "Refusing to install for a missing application user." >&2; exit 77; }
application_uid=$(/usr/bin/id -u "$application_user")
application_home=$(/usr/bin/getent passwd "$application_user" \
    | /usr/bin/awk -F: -v expected_uid="$application_uid" \
        '$3 == expected_uid { count++; home = $6 } END { if (count == 1) print home }')
case "$application_home" in
    /*) ;;
    *) echo "Refusing to install for an invalid application home." >&2; exit 77 ;;
esac
[ "$application_home" != "/" ] && [ "${application_home#*$'\n'}" = "$application_home" ] \
    || { echo "Refusing to install for an invalid application home." >&2; exit 77; }
lock_path=/run/lock/terminal-relay-session-helper.lock
if [ "$(id -u)" != 0 ] || [ -L "$lock_path" ] || [ ! -f "$lock_path" ] \
    || [ "$(/usr/bin/stat -c "%u:%g" "$lock_path")" != "0:0" ]; then
    echo "Refusing to install without the root-owned helper deployment lock." >&2
    exit 77
fi
/bin/chmod 0600 "$lock_path"

privileged() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}
privileged /usr/bin/true

helper_target=/usr/local/bin/terminal-relay-session
chat_target=/usr/local/bin/terminal-relay-chat
mcp_target=/usr/local/bin/terminal-relay-mcp
claude_sessions_target=/usr/local/bin/terminal-relay-claude-sessions
claude_sdk_root=/opt/terminal-relay/claude-session-sdk
claude_sdk_current="$claude_sdk_root/current"
claude_sdk_version=0.2.125
unit_target=/etc/systemd/system/terminal-relay-session-restore@.service
service="terminal-relay-session-restore@$application_user.service"
temporary_directory=""
temporary_helper=""
temporary_chat=""
temporary_mcp=""
temporary_claude_sessions=""
temporary_claude_requirements=""
temporary_unit=""
helper_staged=""
chat_staged=""
mcp_staged=""
claude_sessions_staged=""
claude_sdk_staged=""
claude_current_staged=""
unit_staged=""
helper_backup=""
unit_backup=""
helper_backup_metadata=""
unit_backup_metadata=""
helper_result=new
unit_result=new
helper_applied=0
unit_applied=0
helper_installed_digest=""
unit_installed_digest=""
helper_installed_state=""
mcp_changed=0
chat_changed=0
unit_installed_state=""
service_initial_enabled=false
service_initial_active=false
service_touched=false

if privileged /usr/bin/systemctl is-enabled --quiet "$service" 2>/dev/null; then
    service_initial_enabled=true
fi
if privileged /usr/bin/systemctl is-active --quiet "$service" 2>/dev/null; then
    service_initial_active=true
fi

restore_file() {
    local target="$1"
    local install_result="$2"
    local backup_path="$3"
    local backup_metadata="$4"
    local installed_digest="$5"
    local installed_state="$6"
    local restore_template="$7"
    local current_digest
    local current_state
    local restore_stage

    if [ "$install_result" = unchanged ]; then
        return 0
    fi
    if privileged /usr/bin/test -L "$target" || ! privileged /usr/bin/test -f "$target"; then
        echo "Automatic restore refused an unexpected target type: $target" >&2
        return 1
    fi
    current_digest=$(privileged /usr/bin/sha256sum "$target")
    current_digest=${current_digest%% *}
    current_state=$(privileged /usr/bin/stat -c "%d:%i:%s" "$target")
    if [ -n "$installed_digest" ] && { [ "$current_digest" != "$installed_digest" ] \
        || { [ -n "$installed_state" ] && [ "$current_state" != "$installed_state" ]; }; }; then
        echo "Automatic restore refused because the installed target changed." >&2
        return 1
    fi

    if [ "$install_result" = replaced ]; then
        if privileged /usr/bin/test -L "$backup_path" || ! privileged /usr/bin/test -f "$backup_path"; then
            echo "Automatic restore cannot use the retained backup: $backup_path" >&2
            return 1
        fi
        restore_stage=$(privileged /usr/bin/mktemp "$restore_template")
        privileged /bin/cp -p -- "$backup_path" "$restore_stage"
        privileged /bin/mv -fT -- "$restore_stage" "$target"
        privileged /usr/bin/cmp -s "$backup_path" "$target"
        [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$target")" = "$backup_metadata" ]
    else
        privileged /bin/rm -f -- "$target"
    fi
}

cleanup() {
    local cleanup_status=$?
    local restore_status=0
    trap - EXIT

    if [ "$cleanup_status" -ne 0 ]; then
        if [ "$service_touched" = true ]; then
            privileged /usr/bin/systemctl stop "$service" >/dev/null 2>&1 || true
        fi
        if [ "$unit_applied" -eq 1 ]; then
            restore_file "$unit_target" "$unit_result" "$unit_backup" \
                "$unit_backup_metadata" "$unit_installed_digest" "$unit_installed_state" \
                /etc/systemd/system/.terminal-relay-session-restore.restore.XXXXXX \
                || restore_status=$?
        fi
        if [ "$helper_applied" -eq 1 ]; then
            restore_file "$helper_target" "$helper_result" "$helper_backup" \
                "$helper_backup_metadata" "$helper_installed_digest" "$helper_installed_state" \
                /usr/local/bin/.terminal-relay-session.restore.XXXXXX \
                || restore_status=$?
        fi
        if [ "$unit_applied" -eq 1 ] || [ "$service_touched" = true ]; then
            privileged /usr/bin/systemctl daemon-reload >/dev/null 2>&1 || restore_status=1
        fi
        if [ "$service_touched" = true ]; then
            if [ "$service_initial_enabled" = true ]; then
                privileged /usr/bin/systemctl enable "$service" >/dev/null 2>&1 || restore_status=1
            else
                privileged /usr/bin/systemctl disable "$service" >/dev/null 2>&1 || true
            fi
            if [ "$service_initial_active" = true ]; then
                privileged /usr/bin/systemctl start "$service" >/dev/null 2>&1 || restore_status=1
            fi
        fi
        if [ "$retain_backups" = false ]; then
            echo "Installation failed; no retained host backups were requested." >&2
        elif [ "$restore_status" -ne 0 ]; then
            echo "Automatic rollback failed; retained backups were not discarded." >&2
        else
            echo "Restored the previous helper, unit, and service state after installation failed." >&2
        fi
    fi

    if [ -n "$helper_staged" ]; then
        case "$helper_staged" in
            /usr/local/bin/.terminal-relay-session.install.*)
                privileged /bin/rm -f -- "$helper_staged" || true
                ;;
            *) echo "Refusing to clean unexpected helper stage: $helper_staged" >&2 ;;
        esac
    fi
    if [ -n "$mcp_staged" ]; then
        case "$mcp_staged" in
            /usr/local/bin/.terminal-relay-mcp.install.*)
                privileged /bin/rm -f -- "$mcp_staged" || true
                ;;
            *) echo "Refusing to clean unexpected MCP stage: $mcp_staged" >&2 ;;
        esac
    fi
    if [ -n "$chat_staged" ]; then
        case "$chat_staged" in
            /usr/local/bin/.terminal-relay-chat.install.*)
                privileged /bin/rm -f -- "$chat_staged" || true
                ;;
            *) echo "Refusing to clean unexpected chat broker stage: $chat_staged" >&2 ;;
        esac
    fi
    if [ -n "$claude_sessions_staged" ]; then
        case "$claude_sessions_staged" in
            /usr/local/bin/.terminal-relay-claude-sessions.install.*)
                privileged /bin/rm -f -- "$claude_sessions_staged" || true
                ;;
            *) echo "Refusing to clean unexpected Claude adapter stage: $claude_sessions_staged" >&2 ;;
        esac
    fi
    if [ -n "$claude_sdk_staged" ]; then
        case "$claude_sdk_staged" in
            /opt/terminal-relay/claude-session-sdk/.terminal-relay-sdk.install.*)
                privileged /bin/rm -rf -- "$claude_sdk_staged" || true
                ;;
            *) echo "Refusing to clean unexpected Claude SDK stage: $claude_sdk_staged" >&2 ;;
        esac
    fi
    if [ -n "$claude_current_staged" ]; then
        case "$claude_current_staged" in
            /opt/terminal-relay/claude-session-sdk/.current.install.*)
                privileged /bin/rm -f -- "$claude_current_staged" || true
                ;;
            *) echo "Refusing to clean unexpected Claude SDK link stage: $claude_current_staged" >&2 ;;
        esac
    fi
    if [ -n "$unit_staged" ]; then
        case "$unit_staged" in
            /etc/systemd/system/.terminal-relay-session-restore.install.*)
                privileged /bin/rm -f -- "$unit_staged" || true
                ;;
            *) echo "Refusing to clean unexpected unit stage: $unit_staged" >&2 ;;
        esac
    fi
    if [ -n "$temporary_directory" ]; then
        case "$temporary_directory" in
            /tmp/terminal-relay-session.install.*) /bin/rm -rf -- "$temporary_directory" ;;
            *) echo "Refusing to clean unexpected temporary directory: $temporary_directory" >&2 ;;
        esac
    fi

    [ "$restore_status" -eq 0 ] || exit 1
    exit "$cleanup_status"
}

temporary_directory=$(mktemp -d /tmp/terminal-relay-session.install.XXXXXX)
trap cleanup EXIT
temporary_helper="$temporary_directory/terminal-relay-session"
temporary_chat="$temporary_directory/terminal-relay-chat"
temporary_mcp="$temporary_directory/terminal-relay-mcp"
temporary_claude_sessions="$temporary_directory/terminal-relay-claude-sessions"
temporary_claude_requirements="$temporary_directory/claude-agent-sdk-requirements.txt"
temporary_unit="$temporary_directory/terminal-relay-session-restore@.service"
/usr/bin/tar -xf - -C "$temporary_directory"
/bin/chmod 600 \
    "$temporary_helper" \
    "$temporary_chat" \
    "$temporary_mcp" \
    "$temporary_claude_sessions" \
    "$temporary_claude_requirements" \
    "$temporary_unit"
/bin/bash -n "$temporary_helper"
/usr/bin/python3 -c \
    'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
    "$temporary_chat"
/usr/bin/python3 -c \
    'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
    "$temporary_claude_sessions"
privileged /usr/bin/systemd-analyze verify "$temporary_unit"
helper_source_digest=$(/usr/bin/sha256sum "$temporary_helper")
helper_source_digest=${helper_source_digest%% *}
chat_source_digest=$(/usr/bin/sha256sum "$temporary_chat")
chat_source_digest=${chat_source_digest%% *}
unit_source_digest=$(/usr/bin/sha256sum "$temporary_unit")
unit_source_digest=${unit_source_digest%% *}
mcp_source_digest=$(/usr/bin/sha256sum "$temporary_mcp")
mcp_source_digest=${mcp_source_digest%% *}
claude_sessions_source_digest=$(/usr/bin/sha256sum "$temporary_claude_sessions")
claude_sessions_source_digest=${claude_sessions_source_digest%% *}
claude_requirements_digest=$(/usr/bin/sha256sum "$temporary_claude_requirements")
claude_requirements_digest=${claude_requirements_digest%% *}

if privileged /usr/bin/test -L "$helper_target"; then
    echo "Refusing to replace a symlinked helper: $helper_target" >&2
    exit 1
fi
if privileged /usr/bin/test -e "$helper_target"; then
    privileged /usr/bin/test -f "$helper_target" \
        || { echo "Refusing to replace a non-regular helper: $helper_target" >&2; exit 1; }
    helper_existing_metadata=$(privileged /usr/bin/stat -c "%u:%g:%a" "$helper_target")
    if privileged /usr/bin/cmp -s "$temporary_helper" "$helper_target" \
        && [ "$helper_existing_metadata" = "0:0:755" ]; then
        helper_result=unchanged
    elif [ "$retain_backups" = false ]; then
        helper_result=updated
    else
        helper_result=replaced
        helper_backup_metadata="$helper_existing_metadata"
        timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
        helper_backup="$helper_target.backup.$timestamp"
        suffix=0
        while privileged /usr/bin/test -e "$helper_backup" \
            || privileged /usr/bin/test -L "$helper_backup"; do
            suffix=$((suffix + 1))
            helper_backup="$helper_target.backup.$timestamp.$suffix"
        done
        privileged /bin/cp -p -- "$helper_target" "$helper_backup"
        privileged /usr/bin/cmp -s "$helper_target" "$helper_backup"
        [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$helper_backup")" = "$helper_backup_metadata" ]
    fi
fi

if [ "$helper_result" != unchanged ]; then
    helper_staged=$(privileged /usr/bin/mktemp /usr/local/bin/.terminal-relay-session.install.XXXXXX)
    privileged /usr/bin/install -o root -g root -m 0755 "$temporary_helper" "$helper_staged"
    privileged /usr/bin/cmp -s "$temporary_helper" "$helper_staged"
    [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$helper_staged")" = "0:0:755" ]
    if [ "$helper_result" != updated ]; then
        helper_applied=1
    fi
    if ! privileged /bin/mv -fT -- "$helper_staged" "$helper_target"; then
        helper_applied=0
        exit 1
    fi
    helper_staged=""
fi
helper_installed_digest=$(privileged /usr/bin/sha256sum "$helper_target")
helper_installed_digest=${helper_installed_digest%% *}
helper_installed_state=$(privileged /usr/bin/stat -c "%d:%i:%s" "$helper_target")
[ "$helper_installed_digest" = "$helper_source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$helper_target")" = "0:0:755" ]

if privileged /usr/bin/test -L "$unit_target"; then
    echo "Refusing to replace a symlinked restore unit: $unit_target" >&2
    exit 1
fi
if privileged /usr/bin/test -e "$unit_target"; then
    privileged /usr/bin/test -f "$unit_target" \
        || { echo "Refusing to replace a non-regular restore unit: $unit_target" >&2; exit 1; }
    unit_existing_metadata=$(privileged /usr/bin/stat -c "%u:%g:%a" "$unit_target")
    if privileged /usr/bin/cmp -s "$temporary_unit" "$unit_target" \
        && [ "$unit_existing_metadata" = "0:0:644" ]; then
        unit_result=unchanged
    elif [ "$retain_backups" = false ]; then
        unit_result=updated
    else
        unit_result=replaced
        unit_backup_metadata="$unit_existing_metadata"
        timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
        unit_backup="$unit_target.backup.$timestamp"
        suffix=0
        while privileged /usr/bin/test -e "$unit_backup" \
            || privileged /usr/bin/test -L "$unit_backup"; do
            suffix=$((suffix + 1))
            unit_backup="$unit_target.backup.$timestamp.$suffix"
        done
        privileged /bin/cp -p -- "$unit_target" "$unit_backup"
        privileged /usr/bin/cmp -s "$unit_target" "$unit_backup"
        [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$unit_backup")" = "$unit_backup_metadata" ]
    fi
fi

if [ "$unit_result" != unchanged ]; then
    unit_staged=$(privileged /usr/bin/mktemp /etc/systemd/system/.terminal-relay-session-restore.install.XXXXXX)
    privileged /usr/bin/install -o root -g root -m 0644 "$temporary_unit" "$unit_staged"
    privileged /usr/bin/cmp -s "$temporary_unit" "$unit_staged"
    [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$unit_staged")" = "0:0:644" ]
    if [ "$unit_result" != updated ]; then
        unit_applied=1
    fi
    if ! privileged /bin/mv -fT -- "$unit_staged" "$unit_target"; then
        unit_applied=0
        exit 1
    fi
    unit_staged=""
fi
unit_installed_digest=$(privileged /usr/bin/sha256sum "$unit_target")
unit_installed_digest=${unit_installed_digest%% *}
unit_installed_state=$(privileged /usr/bin/stat -c "%d:%i:%s" "$unit_target")
[ "$unit_installed_digest" = "$unit_source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$unit_target")" = "0:0:644" ]

service_touched=true
privileged /usr/bin/systemctl daemon-reload
privileged /usr/bin/systemd-analyze verify "$unit_target"
privileged /usr/bin/systemctl enable "$service"
if ! privileged /usr/bin/systemctl is-active --quiet "$service"; then
    privileged /usr/bin/systemctl start "$service"
fi
privileged /usr/bin/systemctl is-enabled --quiet "$service"
privileged /usr/bin/systemctl is-active --quiet "$service"
[ "$(privileged /usr/bin/systemctl show -p User --value "$service")" = "$application_user" ]

if privileged /usr/bin/test -L "$mcp_target"; then
    echo "Refusing to replace a symlinked MCP server: $mcp_target" >&2
    exit 1
fi
if privileged /usr/bin/test -e "$mcp_target"; then
    privileged /usr/bin/test -f "$mcp_target" \
        || { echo "Refusing to replace a non-regular MCP server: $mcp_target" >&2; exit 1; }
fi
if ! privileged /usr/bin/test -f "$mcp_target" \
    || ! privileged /usr/bin/cmp -s "$temporary_mcp" "$mcp_target" \
    || [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$mcp_target" 2>/dev/null || true)" != "0:0:755" ]; then
    mcp_staged=$(privileged /usr/bin/mktemp /usr/local/bin/.terminal-relay-mcp.install.XXXXXX)
    privileged /usr/bin/install -o root -g root -m 0755 "$temporary_mcp" "$mcp_staged"
    privileged /usr/bin/cmp -s "$temporary_mcp" "$mcp_staged"
    privileged /bin/mv -fT -- "$mcp_staged" "$mcp_target"
    mcp_staged=""
    mcp_changed=1
fi
[ "$(privileged /usr/bin/sha256sum "$mcp_target" | /usr/bin/awk '{ print $1; exit }')" \
    = "$mcp_source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$mcp_target")" = "0:0:755" ]

if privileged /usr/bin/test -L "$chat_target"; then
    echo "Refusing to replace a symlinked structured chat broker: $chat_target" >&2
    exit 1
fi
if privileged /usr/bin/test -e "$chat_target"; then
    privileged /usr/bin/test -f "$chat_target" \
        || { echo "Refusing to replace a non-regular structured chat broker: $chat_target" >&2; exit 1; }
fi
if ! privileged /usr/bin/test -f "$chat_target" \
    || ! privileged /usr/bin/cmp -s "$temporary_chat" "$chat_target" \
    || [ "$(privileged /usr/bin/stat -c "%u:%g:%a" \
        "$chat_target" 2>/dev/null || true)" != "0:0:755" ]; then
    chat_staged=$(privileged /usr/bin/mktemp \
        /usr/local/bin/.terminal-relay-chat.install.XXXXXX)
    privileged /usr/bin/install -o root -g root -m 0755 \
        "$temporary_chat" "$chat_staged"
    privileged /usr/bin/cmp -s "$temporary_chat" "$chat_staged"
    privileged /bin/mv -fT -- "$chat_staged" "$chat_target"
    chat_staged=""
    chat_changed=1
fi
[ "$(privileged /usr/bin/sha256sum "$chat_target" \
    | /usr/bin/awk '{ print $1; exit }')" = "$chat_source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$chat_target")" = "0:0:755" ]

if ! privileged /usr/bin/dpkg-query -W -f='${Status}' python3-venv 2>/dev/null \
    | /bin/grep -q '^install ok installed$'; then
    privileged /usr/bin/apt-get update
    privileged /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        /usr/bin/apt-get install -y --no-install-recommends python3-venv
fi
claude_sdk_environment_name="sdk-$claude_sdk_version-${claude_requirements_digest:0:16}"
claude_sdk_environment="$claude_sdk_root/$claude_sdk_environment_name"
privileged /usr/bin/install -d -o root -g root -m 0755 "$claude_sdk_root"
if privileged /usr/bin/test -e "$claude_sdk_environment" \
    || privileged /usr/bin/test -L "$claude_sdk_environment"; then
    privileged /usr/bin/test -d "$claude_sdk_environment" \
        && ! privileged /usr/bin/test -L "$claude_sdk_environment" \
        || { echo "Refusing to use an unsafe Claude SDK environment." >&2; exit 1; }
    privileged /usr/bin/test -f "$claude_sdk_environment/requirements.txt" \
        && ! privileged /usr/bin/test -L "$claude_sdk_environment/requirements.txt" \
        || { echo "Refusing to use unsafe Claude SDK requirements." >&2; exit 1; }
    privileged /usr/bin/cmp -s \
        "$temporary_claude_requirements" \
        "$claude_sdk_environment/requirements.txt"
else
    claude_sdk_staged=$(privileged /usr/bin/mktemp -d \
        "$claude_sdk_root/.terminal-relay-sdk.install.XXXXXX")
    privileged /usr/bin/python3 -m venv "$claude_sdk_staged"
    privileged "$claude_sdk_staged/bin/python3" -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        --requirement "$temporary_claude_requirements"
    privileged /usr/bin/install -o root -g root -m 0644 \
        "$temporary_claude_requirements" \
        "$claude_sdk_staged/requirements.txt"
    [ "$(privileged "$claude_sdk_staged/bin/python3" -c \
        'import claude_agent_sdk; print(claude_agent_sdk.__version__)')" \
        = "$claude_sdk_version" ]
    privileged /bin/chown -R root:root "$claude_sdk_staged"
    privileged /bin/chmod -R a+rX,u+w,go-w "$claude_sdk_staged"
    privileged /bin/mv -T "$claude_sdk_staged" "$claude_sdk_environment"
    claude_sdk_staged=""
fi
privileged /bin/chown -R root:root "$claude_sdk_environment"
privileged /bin/chmod -R a+rX,u+w,go-w "$claude_sdk_environment"
if privileged /usr/bin/test -e "$claude_sdk_current" \
    && ! privileged /usr/bin/test -L "$claude_sdk_current"; then
    echo "Refusing to replace an unsafe Claude SDK current pointer." >&2
    exit 1
fi
claude_current_staged=$(privileged /usr/bin/mktemp \
    "$claude_sdk_root/.current.install.XXXXXX")
privileged /bin/rm -f -- "$claude_current_staged"
privileged /bin/ln -s "$claude_sdk_environment_name" "$claude_current_staged"
privileged /bin/mv -Tf "$claude_current_staged" "$claude_sdk_current"
claude_current_staged=""
privileged /usr/bin/test -x "$claude_sdk_current/bin/python3"

if privileged /usr/bin/test -L "$claude_sessions_target"; then
    echo "Refusing to replace a symlinked Claude session adapter." >&2
    exit 1
fi
if privileged /usr/bin/test -e "$claude_sessions_target"; then
    privileged /usr/bin/test -f "$claude_sessions_target" \
        || { echo "Refusing to replace a non-regular Claude session adapter." >&2; exit 1; }
fi
if ! privileged /usr/bin/test -f "$claude_sessions_target" \
    || ! privileged /usr/bin/cmp -s "$temporary_claude_sessions" "$claude_sessions_target" \
    || [ "$(privileged /usr/bin/stat -c "%u:%g:%a" \
        "$claude_sessions_target" 2>/dev/null || true)" != "0:0:755" ]; then
    claude_sessions_staged=$(privileged /usr/bin/mktemp \
        /usr/local/bin/.terminal-relay-claude-sessions.install.XXXXXX)
    privileged /usr/bin/install -o root -g root -m 0755 \
        "$temporary_claude_sessions" "$claude_sessions_staged"
    privileged /usr/bin/cmp -s "$temporary_claude_sessions" "$claude_sessions_staged"
    privileged /bin/mv -fT -- "$claude_sessions_staged" "$claude_sessions_target"
    claude_sessions_staged=""
fi
[ "$(privileged /usr/bin/sha256sum "$claude_sessions_target" \
    | /usr/bin/awk '{ print $1; exit }')" = "$claude_sessions_source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$claude_sessions_target")" = "0:0:755" ]
[ "$(privileged /usr/sbin/runuser -u "$application_user" -- \
    /usr/bin/env \
        HOME="$application_home" \
        USER="$application_user" \
        LOGNAME="$application_user" \
        PATH=/usr/local/bin:/usr/bin:/bin \
        "$claude_sdk_current/bin/python3" \
        "$claude_sessions_target" version)" = "$claude_sdk_version" ]

if [ "$helper_result" != unchanged ] || [ "$mcp_changed" -eq 1 ] \
    || [ "$chat_changed" -eq 1 ]; then
    restart_marker="$application_home/.local/state/terminal-relay/codex-app-server-restart-required"
    privileged /usr/sbin/runuser -u "$application_user" -- \
        /usr/bin/env \
            HOME="$application_home" \
            USER="$application_user" \
            LOGNAME="$application_user" \
            SHELL=/bin/bash \
            PATH=/usr/local/bin:/usr/bin:/bin \
            "$helper_target" __schedule-codex-app-server-restart
    [ "$(privileged /usr/bin/stat -c "%U:%a" "$restart_marker")" \
        = "$application_user:600" ]
fi

printf "__TERMINAL_RELAY_WORKER_INSTALL_V3__|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
    "$helper_result" "$helper_backup" "$helper_installed_digest" "$helper_installed_state" \
    "$unit_result" "$unit_backup" "$unit_installed_digest" "$unit_installed_state" \
    "$service_initial_enabled" "$service_initial_active"
REMOTE_INSTALL
}

remote_install_script="$(render_remote_install_script)"

render_remote_rollback_script() {
    /bin/cat <<'REMOTE_ROLLBACK'
set -euo pipefail
expected_machine="$1"
expected_host="$2"
application_user="$3"
expected_helper_digest="$4"
expected_helper_state="$5"
helper_result="$6"
helper_backup="$7"
expected_unit_digest="$8"
expected_unit_state="$9"
unit_result="${10}"
unit_backup="${11}"
service_initial_enabled="${12}"
service_initial_active="${13}"
helper_target=/usr/local/bin/terminal-relay-session
unit_target=/etc/systemd/system/terminal-relay-session-restore@.service
service="terminal-relay-session-restore@$application_user.service"
lock_path=/run/lock/terminal-relay-session-helper.lock
helper_staged=""
unit_staged=""

cleanup() {
    cleanup_status=$?
    trap - EXIT
    if [ -n "$helper_staged" ]; then
        case "$helper_staged" in
            /usr/local/bin/.terminal-relay-session.rollback.*) /bin/rm -f -- "$helper_staged" ;;
        esac
    fi
    if [ -n "$unit_staged" ]; then
        case "$unit_staged" in
            /etc/systemd/system/.terminal-relay-session-restore.rollback.*) /bin/rm -f -- "$unit_staged" ;;
        esac
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT

if [ "$(id -u)" != 0 ] || [ -L "$lock_path" ] || [ ! -f "$lock_path" ] \
    || [ "$(/usr/bin/stat -c "%u:%g" "$lock_path")" != "0:0" ]; then
    echo "Rollback refused without the root-owned helper deployment lock." >&2
    exit 77
fi
/bin/chmod 0600 "$lock_path"

actual_machine=$(tr -d "\r\n" < /etc/machine-id)
actual_host=$(hostname)
[ "$actual_machine" = "$expected_machine" ] && [ "$actual_host" = "$expected_host" ] \
    || { echo "Rollback refused: worker identity changed." >&2; exit 75; }
[ ! -L "$helper_target" ] && [ -f "$helper_target" ] \
    || { echo "Rollback refused: installed helper is missing, non-regular, or symlinked." >&2; exit 75; }
current_helper_digest=$(/usr/bin/sha256sum "$helper_target")
current_helper_digest=${current_helper_digest%% *}
current_helper_state=$(/usr/bin/stat -c "%d:%i:%s" "$helper_target")
[ "$current_helper_digest" = "$expected_helper_digest" ] \
    && [ "$current_helper_state" = "$expected_helper_state" ] \
    || { echo "Rollback refused: a later deployment changed the installed helper." >&2; exit 75; }
[ ! -L "$unit_target" ] && [ -f "$unit_target" ] \
    || { echo "Rollback refused: installed unit is missing, non-regular, or symlinked." >&2; exit 75; }
current_unit_digest=$(/usr/bin/sha256sum "$unit_target")
current_unit_digest=${current_unit_digest%% *}
current_unit_state=$(/usr/bin/stat -c "%d:%i:%s" "$unit_target")
[ "$current_unit_digest" = "$expected_unit_digest" ] \
    && [ "$current_unit_state" = "$expected_unit_state" ] \
    || { echo "Rollback refused: a later deployment changed the installed unit." >&2; exit 75; }

if [ "$helper_result" = replaced ]; then
    [ ! -L "$helper_backup" ] && [ -f "$helper_backup" ] \
        || { echo "Rollback refused: retained helper backup is invalid." >&2; exit 75; }
    helper_staged=$(/usr/bin/mktemp /usr/local/bin/.terminal-relay-session.rollback.XXXXXX)
    /bin/cp -p -- "$helper_backup" "$helper_staged"
fi
if [ "$unit_result" = replaced ]; then
    [ ! -L "$unit_backup" ] && [ -f "$unit_backup" ] \
        || { echo "Rollback refused: retained unit backup is invalid." >&2; exit 75; }
    unit_staged=$(/usr/bin/mktemp /etc/systemd/system/.terminal-relay-session-restore.rollback.XXXXXX)
    /bin/cp -p -- "$unit_backup" "$unit_staged"
fi

/usr/bin/systemctl stop "$service" >/dev/null 2>&1 || true
case "$helper_result" in
    replaced) /bin/mv -fT -- "$helper_staged" "$helper_target"; helper_staged="" ;;
    new) /bin/rm -f -- "$helper_target" ;;
    unchanged) ;;
    *) echo "Rollback refused: invalid helper result." >&2; exit 75 ;;
esac
case "$unit_result" in
    replaced) /bin/mv -fT -- "$unit_staged" "$unit_target"; unit_staged="" ;;
    new) /bin/rm -f -- "$unit_target" ;;
    unchanged) ;;
    *) echo "Rollback refused: invalid unit result." >&2; exit 75 ;;
esac
/usr/bin/systemctl daemon-reload
if [ "$service_initial_enabled" = true ]; then
    /usr/bin/systemctl enable "$service" >/dev/null
else
    /usr/bin/systemctl disable "$service" >/dev/null 2>&1 || true
fi
if [ "$service_initial_active" = true ]; then
    /usr/bin/systemctl start "$service"
fi
echo "Restored the previous helper, unit, and service state."
REMOTE_ROLLBACK
}

remote_rollback_script="$(render_remote_rollback_script)"
remote_install_command="$(build_locked_remote_command \
    "$admin_uid" "$remote_install_script" terminal-relay-install \
    "$application_machine" "$application_host" "$application_user" "$retain_backups")"
rollback_validation_command="$(build_locked_remote_command \
    "$admin_uid" "$remote_rollback_script" terminal-relay-rollback \
    "$application_machine" "$application_host" "$application_user" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    1:2:3 new '' \
    0000000000000000000000000000000000000000000000000000000000000000 \
    4:5:6 new '' false false)"
if ! validate_remote_rendering install "$remote_install_script" "$remote_install_command" \
    || ! validate_remote_rendering rollback "$remote_rollback_script" "$rollback_validation_command"; then
    echo "Remote helper scripts failed local generation validation." >&2
    exit 65
fi

# The validated installer is explicitly quoted for remote Bash; tar remains stdin.
# shellcheck disable=SC2029
install_output="$(/usr/bin/tar --no-xattrs -C "$repository_root/Server" -cf - \
    terminal-relay-session \
    terminal-relay-chat \
    terminal-relay-mcp \
    terminal-relay-claude-sessions \
    claude-agent-sdk-requirements.txt \
    terminal-relay-session-restore@.service \
    | /usr/bin/ssh "$admin_target" "$remote_install_command")"

install_record="$(printf '%s\n' "$install_output" | /usr/bin/sed -n \
    's/^__TERMINAL_RELAY_WORKER_INSTALL_V3__|//p' | /usr/bin/tail -n 1)"
IFS='|' read -r helper_result helper_backup helper_installed_digest helper_installed_state \
    unit_result unit_backup unit_installed_digest unit_installed_state \
    service_initial_enabled service_initial_active extra <<< "$install_record"
if [[ -n "${extra:-}" \
    || ! "$helper_installed_digest" =~ ^[a-f0-9]{64}$ \
    || ! "$helper_installed_state" =~ ^[0-9]+:[0-9]+:[0-9]+$ \
    || ! "$unit_installed_digest" =~ ^[a-f0-9]{64}$ \
    || ! "$unit_installed_state" =~ ^[0-9]+:[0-9]+:[0-9]+$ \
    || ! "$service_initial_enabled" =~ ^(true|false)$ \
    || ! "$service_initial_active" =~ ^(true|false)$ ]]; then
    echo "Remote installer returned an invalid completion record." >&2
    exit 70
fi
case "$helper_result" in
    replaced)
        [[ "$helper_backup" =~ ^/usr/local/bin/terminal-relay-session\.backup\.[A-Za-z0-9.]+$ ]] \
            || { echo "Remote installer returned an invalid helper backup: $helper_backup" >&2; exit 70; }
        ;;
    new|updated|unchanged)
        [[ -z "$helper_backup" ]] \
            || { echo "Remote installer returned an unexpected helper backup: $helper_backup" >&2; exit 70; }
        ;;
    *) echo "Remote installer returned an invalid helper result: $helper_result" >&2; exit 70 ;;
esac
case "$unit_result" in
    replaced)
        [[ "$unit_backup" =~ ^/etc/systemd/system/terminal-relay-session-restore@\.service\.backup\.[A-Za-z0-9.]+$ ]] \
            || { echo "Remote installer returned an invalid unit backup: $unit_backup" >&2; exit 70; }
        ;;
    new|updated|unchanged)
        [[ -z "$unit_backup" ]] \
            || { echo "Remote installer returned an unexpected unit backup: $unit_backup" >&2; exit 70; }
        ;;
    *) echo "Remote installer returned an invalid unit result: $unit_result" >&2; exit 70 ;;
esac

runtime_manifest_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/terminal-relay-runtime-manifest.XXXXXX")"
runtime_manifest_file="$runtime_manifest_directory/runtime-manifest.json"
"$script_directory/write-installed-runtime-manifest.sh" \
    "$runtime_version" \
    "$runtime_manifest_file"
render_runtime_control_script() {
    /bin/cat <<'REMOTE_RUNTIME_CONTROLS'
set -euo pipefail
temporary_directory="$(/usr/bin/mktemp -d /tmp/terminal-relay-runtime-controls.XXXXXX)"
cleanup() {
    exit_code=$?
    trap - EXIT
    case "$temporary_directory" in
        /tmp/terminal-relay-runtime-controls.*)
            /bin/rm -rf -- "$temporary_directory"
            ;;
        *) exit_code=1 ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT
/usr/bin/tar --no-same-owner --no-same-permissions -xf - -C "$temporary_directory"
/usr/bin/install -d -o root -g root -m 0755 \
    /etc/terminal-relay \
    /opt/terminal-relay/claude-session-sdk \
    /usr/local/libexec
/usr/bin/install -o root -g root -m 0644 \
    "$temporary_directory/runtime-manifest.json" \
    /etc/terminal-relay/runtime-manifest.json
/usr/bin/install -o root -g root -m 0644 \
    "$temporary_directory/terminal-relay-runtime-update.pub" \
    /etc/terminal-relay/runtime-update-public.pem
/usr/bin/install -o root -g root -m 0644 \
    "$temporary_directory/claude-agent-sdk-requirements.txt" \
    /opt/terminal-relay/claude-session-sdk/runtime-requirements.txt
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-agent-update" \
    /usr/local/sbin/terminal-relay-agent-update
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-runtime-update" \
    /usr/local/sbin/terminal-relay-runtime-update
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-review-gateway" \
    /usr/local/libexec/terminal-relay-command-gateway
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-mobile-gateway" \
    /usr/local/bin/terminal-relay-mobile-gateway
for unit in \
    terminal-relay-agent-update.service \
    terminal-relay-agent-update.timer \
    terminal-relay-runtime-update.service \
    terminal-relay-runtime-update.timer \
    terminal-relay-runtime-update.path; do
    /usr/bin/install -o root -g root -m 0644 \
        "$temporary_directory/$unit" \
        "/etc/systemd/system/$unit"
done
/usr/bin/systemctl daemon-reload
/usr/bin/systemd-analyze verify \
    /etc/systemd/system/terminal-relay-agent-update.service \
    /etc/systemd/system/terminal-relay-agent-update.timer \
    /etc/systemd/system/terminal-relay-runtime-update.service \
    /etc/systemd/system/terminal-relay-runtime-update.timer \
    /etc/systemd/system/terminal-relay-runtime-update.path
/usr/bin/systemctl enable --now \
    terminal-relay-agent-update.timer \
    terminal-relay-runtime-update.timer \
    terminal-relay-runtime-update.path
REMOTE_RUNTIME_CONTROLS
}
runtime_control_script="$(render_runtime_control_script)"
runtime_control_command="$(build_locked_remote_command \
    "$admin_uid" "$runtime_control_script" terminal-relay-runtime-controls)"
set +e
# shellcheck disable=SC2029 # The audited fixed command is intentionally expanded locally.
/usr/bin/tar --no-xattrs -cf - \
    -C "$runtime_manifest_directory" runtime-manifest.json \
    -C "$repository_root/Server" \
        claude-agent-sdk-requirements.txt \
        terminal-relay-agent-update \
        terminal-relay-agent-update.service \
        terminal-relay-agent-update.timer \
        terminal-relay-runtime-update \
        terminal-relay-runtime-update.service \
        terminal-relay-runtime-update.timer \
        terminal-relay-runtime-update.path \
        terminal-relay-runtime-update.pub \
        terminal-relay-review-gateway \
        terminal-relay-mobile-gateway \
    | /usr/bin/ssh "$admin_target" "$runtime_control_command"
runtime_control_status="${PIPESTATUS[1]}"
set -e
/bin/unlink "$runtime_manifest_file"
/bin/rmdir "$runtime_manifest_directory"
[[ "$runtime_control_status" -eq 0 ]] || {
    echo "Installing the worker runtime update controls failed." >&2
    exit "$runtime_control_status"
}

echo "Installed helper, restore unit, and automatic runtime update controls."
[[ "$helper_result" != replaced ]] || echo "Helper backup retained at $helper_backup"
[[ "$unit_result" != replaced ]] || echo "Unit backup retained at $unit_backup"

if [[ "$retain_backups" == true ]]; then
    rollback_remote="$(build_locked_remote_command \
        "$admin_uid" "$remote_rollback_script" terminal-relay-rollback \
        "$application_machine" "$application_host" "$application_user" \
        "$helper_installed_digest" "$helper_installed_state" "$helper_result" "$helper_backup" \
        "$unit_installed_digest" "$unit_installed_state" "$unit_result" "$unit_backup" \
        "$service_initial_enabled" "$service_initial_active")"
    printf 'Rollback:'
    printf ' %q' /usr/bin/ssh "$admin_target" "$rollback_remote"
    printf '\n'
fi
