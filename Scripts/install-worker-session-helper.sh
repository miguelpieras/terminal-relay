#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
source_helper="$repository_root/Server/terminal-relay-session"
default_application_target="terminal-relay-worker-1"
default_admin_target="root@terminal-relay-worker-1"
remote_lock_path="/run/lock/terminal-relay-session-helper.lock"

usage() {
    cat >&2 <<'EOF'
usage: install-worker-session-helper.sh [application-ssh-target [admin-ssh-target]]

The application target verifies the worker account and /usr/bin/tmux. The admin
target must reach the same machine as root or as an account with non-interactive
sudo. Defaults: terminal-relay-worker-1 and root@terminal-relay-worker-1.
EOF
}

[[ $# -le 2 ]] || { usage; exit 64; }
application_target="${1:-$default_application_target}"
if [[ $# -eq 2 ]]; then
    admin_target="$2"
elif [[ "$application_target" == "$default_application_target" ]]; then
    admin_target="$default_admin_target"
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
            [[ "$script" == *'case "$staged_path" in'* \
                && "$script" == *'"$source_digest"'* \
                && "$script" == *'"$install_result"'* ]] || return 1
            ;;
        rollback)
            # shellcheck disable=SC2016
            [[ "$script" == *'case "$staged" in'* \
                && "$script" == *'"$expected_digest"'* \
                && "$script" == *'"$install_result"'* ]] || return 1
            ;;
        *) return 64 ;;
    esac
}

validate_ssh_target "application" "$application_target"
validate_ssh_target "admin" "$admin_target"
[[ -f "$source_helper" && ! -L "$source_helper" ]] \
    || { echo "Missing regular worker helper source: $source_helper" >&2; exit 66; }
/bin/bash -n "$source_helper" \
    || { echo "Worker helper source failed Bash syntax validation." >&2; exit 65; }

probe_target() {
    local target="$1"
    /usr/bin/ssh "$target" '
set -eu
machine_id=$(tr -d "\r\n" < /etc/machine-id)
host_name=$(hostname)
user_name=$(id -un)
user_id=$(id -u)
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
    "tmux|$tmux_path" \
    "tmux-version|$tmux_version" \
    "flock|$flock_path" \
    "pidfd|$pidfd_support" \
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
application_tmux="$(probe_field "$application_probe" tmux)"
application_tmux_version="$(probe_field "$application_probe" tmux-version)"
application_flock="$(probe_field "$application_probe" flock)"
application_pidfd="$(probe_field "$application_probe" pidfd)"

if [[ ! "$application_machine" =~ ^[A-Fa-f0-9]{32}$ \
    || -z "$application_host" || "$application_host" == *$'\n'* \
    || -z "$application_user" \
    || ! "$application_uid" =~ ^[0-9]+$ ]]; then
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
echo "Verified $application_user@$application_host (uid $application_uid, machine $application_machine)"
echo "Verified $application_tmux_version at $application_tmux"
echo "Verified /usr/bin/flock and /usr/bin/python3 Linux pidfd signaling"

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
actual_machine=$(tr -d "\r\n" < /etc/machine-id)
actual_host=$(hostname)
if [ "$actual_machine" != "$expected_machine" ] || [ "$actual_host" != "$expected_host" ]; then
    echo "Refusing to install: worker identity changed inside the install connection." >&2
    exit 77
fi
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

target=/usr/local/bin/terminal-relay-session
temporary_directory=""
temporary_file=""
staged_path=""
backup_path=""
backup_metadata=""
install_result=new
replacement_applied=0
installed_digest=""
installed_state=""

restore_previous() {
    local current_digest
    local current_state
    local restore_stage

    if [ "$install_result" = new ] && ! privileged /usr/bin/test -e "$target" \
        && ! privileged /usr/bin/test -L "$target"; then
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
        restore_stage=$(privileged /usr/bin/mktemp /usr/local/bin/.terminal-relay-session.restore.XXXXXX)
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

    if [ "$cleanup_status" -ne 0 ] && [ "$replacement_applied" -eq 1 ]; then
        restore_previous || restore_status=$?
        if [ "$restore_status" -ne 0 ]; then
            echo "Automatic rollback failed; the retained backup was not discarded." >&2
        else
            echo "Restored the previous helper after installation failed." >&2
        fi
    fi

    if [ -n "$staged_path" ]; then
        case "$staged_path" in
            /usr/local/bin/.terminal-relay-session.install.*)
                privileged /bin/rm -f -- "$staged_path" || true
                ;;
            *) echo "Refusing to clean unexpected staged path: $staged_path" >&2 ;;
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
temporary_file="$temporary_directory/terminal-relay-session"
/usr/bin/tar -xf - -C "$temporary_directory"
/bin/chmod 600 "$temporary_file"
/bin/bash -n "$temporary_file"
source_digest=$(/usr/bin/sha256sum "$temporary_file")
source_digest=${source_digest%% *}

if privileged /usr/bin/test -L "$target"; then
    echo "Refusing to replace a symlinked helper: $target" >&2
    exit 1
fi
if privileged /usr/bin/test -e "$target"; then
    privileged /usr/bin/test -f "$target" \
        || { echo "Refusing to replace a non-regular helper: $target" >&2; exit 1; }
    existing_metadata=$(privileged /usr/bin/stat -c "%u:%g:%a" "$target")
    if privileged /usr/bin/cmp -s "$temporary_file" "$target" \
        && [ "$existing_metadata" = "0:0:755" ]; then
        current_state=$(privileged /usr/bin/stat -c "%d:%i:%s" "$target")
        printf "__TERMINAL_RELAY_WORKER_INSTALL_V2__|unchanged||%s|%s\n" "$source_digest" "$current_state"
        exit 0
    fi

    install_result=replaced
    backup_metadata="$existing_metadata"
    timestamp=$(/usr/bin/date -u +%Y%m%dT%H%M%SZ)
    backup_path="$target.backup.$timestamp"
    suffix=0
    while privileged /usr/bin/test -e "$backup_path" \
        || privileged /usr/bin/test -L "$backup_path"; do
        suffix=$((suffix + 1))
        backup_path="$target.backup.$timestamp.$suffix"
    done
    privileged /bin/cp -p -- "$target" "$backup_path"
    privileged /usr/bin/cmp -s "$target" "$backup_path"
    [ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$backup_path")" = "$backup_metadata" ]
fi

staged_path=$(privileged /usr/bin/mktemp /usr/local/bin/.terminal-relay-session.install.XXXXXX)
privileged /usr/bin/install -o root -g root -m 0755 "$temporary_file" "$staged_path"
privileged /usr/bin/test -f "$staged_path"
! privileged /usr/bin/test -L "$staged_path"
privileged /usr/bin/cmp -s "$temporary_file" "$staged_path"
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$staged_path")" = "0:0:755" ]

replacement_applied=1
if ! privileged /bin/mv -fT -- "$staged_path" "$target"; then
    replacement_applied=0
    exit 1
fi
staged_path=""
installed_digest=$(privileged /usr/bin/sha256sum "$target")
installed_digest=${installed_digest%% *}
installed_state=$(privileged /usr/bin/stat -c "%d:%i:%s" "$target")

! privileged /usr/bin/test -L "$target"
privileged /usr/bin/test -f "$target"
[ "$installed_digest" = "$source_digest" ]
[ "$(privileged /usr/bin/stat -c "%u:%g:%a" "$target")" = "0:0:755" ]

printf "__TERMINAL_RELAY_WORKER_INSTALL_V2__|%s|%s|%s|%s\n" \
    "$install_result" "$backup_path" "$installed_digest" "$installed_state"
REMOTE_INSTALL
}

remote_install_script="$(render_remote_install_script)"

render_remote_rollback_script() {
    /bin/cat <<'REMOTE_ROLLBACK'
set -euo pipefail
expected_machine="$1"
expected_host="$2"
expected_digest="$3"
expected_state="$4"
install_result="$5"
backup_path="$6"
target=/usr/local/bin/terminal-relay-session
lock_path=/run/lock/terminal-relay-session-helper.lock

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
[ ! -L "$target" ] && [ -f "$target" ] \
    || { echo "Rollback refused: installed helper is missing, non-regular, or symlinked." >&2; exit 75; }
current_digest=$(/usr/bin/sha256sum "$target")
current_digest=${current_digest%% *}
current_state=$(/usr/bin/stat -c "%d:%i:%s" "$target")
[ "$current_digest" = "$expected_digest" ] && [ "$current_state" = "$expected_state" ] \
    || { echo "Rollback refused: a later deployment changed the installed helper." >&2; exit 75; }

if [ "$install_result" = replaced ]; then
    [ ! -L "$backup_path" ] && [ -f "$backup_path" ] \
        || { echo "Rollback refused: retained backup is missing, non-regular, or symlinked." >&2; exit 75; }
    staged=$(/usr/bin/mktemp /usr/local/bin/.terminal-relay-session.rollback.XXXXXX)
    cleanup() {
        cleanup_status=$?
        trap - EXIT
        case "$staged" in
            /usr/local/bin/.terminal-relay-session.rollback.*) /bin/rm -f -- "$staged" ;;
        esac
        exit "$cleanup_status"
    }
    trap cleanup EXIT
    /bin/cp -p -- "$backup_path" "$staged"
    /bin/mv -fT -- "$staged" "$target"
    staged=""
    /usr/bin/cmp -s "$backup_path" "$target"
    echo "Restored $backup_path"
else
    /bin/rm -f -- "$target"
    echo "Removed the newly installed helper."
fi
REMOTE_ROLLBACK
}

remote_rollback_script="$(render_remote_rollback_script)"
remote_install_command="$(build_locked_remote_command \
    "$admin_uid" "$remote_install_script" terminal-relay-install \
    "$application_machine" "$application_host")"
rollback_validation_command="$(build_locked_remote_command \
    "$admin_uid" "$remote_rollback_script" terminal-relay-rollback \
    "$application_machine" "$application_host" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    1:2:3 new '')"
if ! validate_remote_rendering install "$remote_install_script" "$remote_install_command" \
    || ! validate_remote_rendering rollback "$remote_rollback_script" "$rollback_validation_command"; then
    echo "Remote helper scripts failed local generation validation." >&2
    exit 65
fi

# The validated installer is explicitly quoted for remote Bash; tar remains stdin.
# shellcheck disable=SC2029
install_output="$(/usr/bin/tar --no-xattrs -C "$repository_root/Server" -cf - terminal-relay-session | /usr/bin/ssh "$admin_target" "$remote_install_command")"

install_record="$(printf '%s\n' "$install_output" | /usr/bin/sed -n \
    's/^__TERMINAL_RELAY_WORKER_INSTALL_V2__|//p' | /usr/bin/tail -n 1)"
IFS='|' read -r install_result backup_path installed_digest installed_state extra <<< "$install_record"
if [[ -n "${extra:-}" \
    || ! "$installed_digest" =~ ^[a-f0-9]{64}$ \
    || ! "$installed_state" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
    echo "Remote installer returned an invalid completion record." >&2
    exit 70
fi
case "$install_result" in
    replaced)
        [[ "$backup_path" =~ ^/usr/local/bin/terminal-relay-session\.backup\.[A-Za-z0-9.]+$ ]] \
            || { echo "Remote installer returned an invalid backup path: $backup_path" >&2; exit 70; }
        ;;
    new|unchanged)
        [[ -z "$backup_path" ]] \
            || { echo "Remote installer returned an unexpected backup path: $backup_path" >&2; exit 70; }
        ;;
    *) echo "Remote installer returned an invalid result: $install_result" >&2; exit 70 ;;
esac

if [[ "$install_result" == "unchanged" ]]; then
    echo "Installed helper already matched root:root 0755; no managed file was written."
    rollback_remote="/usr/bin/true"
else
    rollback_script="$remote_rollback_script"
    rollback_remote="$(build_locked_remote_command \
        "$admin_uid" "$rollback_script" terminal-relay-rollback \
        "$application_machine" "$application_host" "$installed_digest" \
        "$installed_state" "$install_result" "$backup_path")"
    echo "Installed /usr/local/bin/terminal-relay-session atomically (root:root 0755)."
    if [[ "$install_result" == "replaced" ]]; then
        echo "Backup retained at $backup_path"
    fi
fi

printf 'Rollback:'
printf ' %q' /usr/bin/ssh "$admin_target" "$rollback_remote"
printf '\n'
