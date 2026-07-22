#!/bin/bash
set -euo pipefail

readonly installer_version="terminal-relay-worker-v1"
readonly runtime_user="terminal-relay"
readonly runtime_group="terminal-relay"
readonly runtime_home="/home/terminal-relay"
readonly state_directory="/etc/terminal-relay"
readonly version_file="$state_directory/installer-version"
readonly worker_id_file="$state_directory/worker-id"
readonly display_name_file="$state_directory/display-name"
readonly ssh_keys_marker="$state_directory/authorized-keys-installed"
readonly workspace_directory="/workspace"
readonly launcher_destination="/usr/local/bin/terminal-relay-session"
readonly codex_destination="/usr/bin/codex"
readonly claude_destination="/usr/bin/claude"
readonly codex_root="/opt/terminal-relay"
readonly codex_home="$codex_root/codex"
readonly codex_current_link="$codex_home/packages/standalone/current"
readonly claude_key_destination="/etc/apt/keyrings/claude-code.asc"
readonly claude_source_destination="/etc/apt/sources.list.d/claude-code.list"
readonly claude_key_url="https://downloads.claude.ai/keys/claude-code.asc"
readonly claude_key_fingerprint="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
readonly claude_repository="deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main"
readonly codex_installer_url="https://chatgpt.com/codex/install.sh"
readonly CODEX_RELEASE="${CODEX_RELEASE:-latest}"
readonly minimum_memory_kib=3900000

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
launcher_source="$script_directory/terminal-relay-session"
worker_config_directory="$script_directory/worker-config"
backup_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary_directory=""
installation_started=false
installation_succeeded=false
worker_id=""
worker_short_id=""
worker_name=""
worker_hostname=""
original_hostname=""
hostname_was_changed=false

declare -a rollback_destinations=()
declare -a rollback_backups=()
declare -a rollback_had_previous=()
declare -a rollback_active=()

log() {
    printf '[terminal-relay] %s\n' "$*"
}

fail() {
    printf '[terminal-relay] ERROR: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

next_backup_path() {
    local destination="$1"
    local candidate="$destination.backup.$backup_timestamp"
    local suffix=1

    while path_exists "$candidate"; do
        candidate="$destination.backup.$backup_timestamp.$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$candidate"
}

prepare_managed_rollback() {
    local destination="$1"
    local announce="${2:-true}"
    local backup=""
    local had_previous=false

    if path_exists "$destination"; then
        backup="$(next_backup_path "$destination")"
        /bin/cp -a -- "$destination" "$backup"
        had_previous=true
        if [[ "$announce" == true ]]; then
            log "Backed up $destination to $backup"
        fi
    fi

    rollback_destinations+=("$destination")
    rollback_backups+=("$backup")
    rollback_had_previous+=("$had_previous")
    rollback_active+=(true)
}

managed_paths_equal() {
    local first="$1"
    local second="$2"

    if [[ -L "$first" && -L "$second" ]]; then
        [[ "$(/usr/bin/readlink "$first")" == "$(/usr/bin/readlink "$second")" ]]
    elif [[ -f "$first" && ! -L "$first" && -f "$second" && ! -L "$second" ]]; then
        /usr/bin/cmp -s -- "$first" "$second"
    else
        return 1
    fi
}

discard_rollback_if_unchanged() {
    local index="$1"
    local destination="${rollback_destinations[$index]}"
    local backup="${rollback_backups[$index]}"

    if [[ "${rollback_had_previous[$index]}" == true ]] \
        && managed_paths_equal "$backup" "$destination"; then
        /bin/rm -f -- "$backup"
        rollback_active[index]=false
    fi
}

announce_rollback_backup() {
    local index="$1"

    if [[ "${rollback_active[$index]}" == true \
        && "${rollback_had_previous[$index]}" == true ]]; then
        log "Backed up ${rollback_destinations[$index]} to ${rollback_backups[$index]}"
    fi
}

install_managed_file() {
    local source="$1"
    local destination="$2"
    local mode="$3"
    local parent
    local temporary_file

    if [[ -f "$destination" && ! -L "$destination" ]] \
        && /usr/bin/cmp -s -- "$source" "$destination" \
        && [[ "$(/usr/bin/stat -c '%U:%G:%a' "$destination")" == "root:root:$mode" ]]; then
        log "Already current: $destination"
        return
    fi

    parent="$(dirname "$destination")"
    /usr/bin/install -d -o root -g root -m 0755 "$parent"
    prepare_managed_rollback "$destination"
    temporary_file="$(mktemp "$parent/.terminal-relay-install.XXXXXX")"
    /usr/bin/install -o root -g root -m "$mode" "$source" "$temporary_file"
    /bin/mv -f -- "$temporary_file" "$destination"
    log "Installed $destination"
}

rollback_managed_files() {
    local index
    local destination
    local backup

    for ((index=${#rollback_destinations[@]} - 1; index >= 0; index--)); do
        if [[ "${rollback_active[$index]}" != true ]]; then
            continue
        fi
        destination="${rollback_destinations[$index]}"
        backup="${rollback_backups[$index]}"
        /bin/rm -f -- "$destination"
        if [[ "${rollback_had_previous[$index]}" == true ]] && path_exists "$backup"; then
            /bin/mv -f -- "$backup" "$destination"
            log "Restored $destination after installation failure"
        fi
    done
}

cleanup() {
    local exit_code=$?
    local temporary_parent
    local temporary_name

    trap - EXIT
    if [[ "$installation_started" == true && "$installation_succeeded" != true && $exit_code -ne 0 ]]; then
        rollback_managed_files || true
        if [[ "$hostname_was_changed" == true && -n "$original_hostname" ]]; then
            if /bin/hostname "$original_hostname" 2>/dev/null; then
                log "Restored live hostname after installation failure."
            else
                printf '[terminal-relay] WARNING: unable to restore live hostname to %s\n' \
                    "$original_hostname" >&2
            fi
        fi
    fi

    if [[ -n "$temporary_directory" ]] && path_exists "$temporary_directory"; then
        temporary_parent="$(dirname "$temporary_directory")"
        temporary_name="$(basename "$temporary_directory")"
        if [[ "$temporary_parent" == "/tmp" && "$temporary_name" == terminal-relay-install.* ]]; then
            /bin/rm -rf -- "$temporary_directory"
        else
            printf '[terminal-relay] Refusing to clean unexpected temporary path: %s\n' "$temporary_directory" >&2
            exit 1
        fi
    fi

    exit "$exit_code"
}
trap cleanup EXIT

validate_source_bundle() {
    local required_file

    for required_file in \
        "$launcher_source" \
        "$worker_config_directory/install.sh" \
        "$worker_config_directory/AGENTS.md" \
        "$worker_config_directory/CLAUDE.md"; do
        if [[ ! -f "$required_file" || -L "$required_file" ]]; then
            fail "Missing or unsafe installer bundle file: $required_file"
        fi
    done
}

validate_platform() {
    local architecture
    local memory_kib

    [[ -r /etc/os-release ]] || fail "Unable to read /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
        || fail "Supported platform is Ubuntu 24.04; found ${PRETTY_NAME:-unknown}."

    architecture="$(/usr/bin/dpkg --print-architecture)"
    [[ "$architecture" == "amd64" ]] \
        || fail "Supported architecture is amd64; found $architecture."

    memory_kib="$(/usr/bin/awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
    [[ "$memory_kib" =~ ^[0-9]+$ ]] || fail "Unable to determine installed memory."
    ((memory_kib >= minimum_memory_kib)) \
        || fail "At least 4 GB RAM is required; found ${memory_kib} KiB."
}

validate_root_state_file() {
    local path="$1"

    [[ -f "$path" && ! -L "$path" ]] || fail "Invalid managed state file: $path"
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$path")" == "root:root:644" ]] \
        || fail "Unexpected ownership or mode on managed state file: $path"
}

is_valid_worker_name() {
    local candidate="$1"

    [[ "$candidate" == "Terminal Relay Worker $worker_short_id" \
        || "$candidate" =~ ^Terminal\ Relay\ Worker\ [1-9][0-9]{0,5}$ ]]
}

validate_existing_runtime_user() {
    local passwd_entry
    local user_home
    local user_shell
    local user_gid
    local expected_gid

    if ! /usr/bin/getent passwd "$runtime_user" >/dev/null; then
        return
    fi

    passwd_entry="$(/usr/bin/getent passwd "$runtime_user")"
    IFS=: read -r _ _ _ user_gid _ user_home user_shell <<< "$passwd_entry"
    [[ "$user_home" == "$runtime_home" && "$user_shell" == "/bin/bash" ]] \
        || fail "Existing managed user has unexpected home or shell."
    /usr/bin/getent group "$runtime_group" >/dev/null \
        || fail "Existing managed user is missing its primary group."
    expected_gid="$(/usr/bin/getent group "$runtime_group" | /usr/bin/cut -d: -f3)"
    [[ "$user_gid" == "$expected_gid" ]] \
        || fail "Existing managed user has an unexpected primary group."
}

validate_existing_codex() {
    local resolved_codex
    local resolved_current

    if path_exists "$codex_current_link"; then
        [[ -L "$codex_current_link" ]] \
            || fail "Existing managed Codex current path is not a symlink."
        resolved_current="$(/usr/bin/readlink -f "$codex_current_link")" \
            || fail "Existing managed Codex current path is a broken symlink."
        case "$resolved_current" in
            "$codex_home"/packages/standalone/releases/*) ;;
            *) fail "Existing Codex current path is not managed under $codex_home." ;;
        esac
        [[ -d "$resolved_current" ]] || fail "Existing Codex release path is not a directory."
    fi

    if ! path_exists "$codex_destination"; then
        return
    fi
    [[ -L "$codex_destination" ]] \
        || fail "Existing managed Codex command is not the standalone installer symlink."
    resolved_codex="$(/usr/bin/readlink -f "$codex_destination")" \
        || fail "Existing managed Codex command is a broken symlink."
    case "$resolved_codex" in
        "$codex_home"/packages/standalone/releases/*/bin/codex|\
        "$codex_home"/packages/standalone/releases/*/codex) ;;
        *) fail "Existing $codex_destination is not managed under $codex_home." ;;
    esac
    [[ -x "$resolved_codex" ]] || fail "Existing managed Codex command is not executable."
}

validate_existing_claude() {
    if ! path_exists "$claude_destination"; then
        return
    fi
    /usr/bin/dpkg-query -S "$claude_destination" 2>/dev/null | /bin/grep -q '^claude-code:' \
        || fail "Existing $claude_destination is not owned by the claude-code package."
}

validate_managed_state() {
    local state_is_managed=false
    local entry
    local entry_name

    if path_exists "$state_directory"; then
        [[ -d "$state_directory" && ! -L "$state_directory" ]] \
            || fail "Unexpected managed state path: $state_directory"
        [[ "$(/usr/bin/stat -c '%U:%G:%a' "$state_directory")" == "root:root:755" ]] \
            || fail "Unexpected ownership or mode on $state_directory."
        path_exists "$version_file" \
            || fail "Existing $state_directory is not a Terminal Relay V1 installation."
        validate_root_state_file "$version_file"
        [[ "$(<"$version_file")" == "$installer_version" ]] \
            || fail "Unsupported or unexpected installer state in $version_file."
        [[ "$(/usr/bin/wc -c < "$version_file" | tr -d '[:space:]')" \
            == "$(( ${#installer_version} + 1 ))" ]] \
            || fail "Installer state file contains unexpected data."
        state_is_managed=true

        while IFS= read -r -d '' entry; do
            entry_name="$(basename "$entry")"
            case "$entry_name" in
                installer-version|worker-id|display-name|authorized-keys-installed) ;;
                *) fail "Unexpected state entry: $entry" ;;
            esac
        done < <(/usr/bin/find "$state_directory" -mindepth 1 -maxdepth 1 -print0)

        if path_exists "$worker_id_file"; then
            validate_root_state_file "$worker_id_file"
            IFS= read -r worker_id < "$worker_id_file" \
                || fail "Unable to read worker identity."
            [[ "$worker_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
                || fail "Invalid persisted worker identity in $worker_id_file."
            [[ "$(/usr/bin/wc -c < "$worker_id_file" | tr -d '[:space:]')" == "37" ]] \
                || fail "Worker identity file contains unexpected data."
            worker_short_id="${worker_id%%-*}"
        fi
        if path_exists "$display_name_file"; then
            [[ -n "$worker_short_id" ]] \
                || fail "A managed display name exists without a worker identity."
            validate_root_state_file "$display_name_file"
            IFS= read -r worker_name < "$display_name_file" \
                || fail "Unable to read the managed display name."
            is_valid_worker_name "$worker_name" \
                || fail "Invalid managed display name in $display_name_file."
            [[ "$(/usr/bin/wc -c < "$display_name_file" | tr -d '[:space:]')" \
                == "$(( ${#worker_name} + 1 ))" ]] \
                || fail "Managed display name contains unexpected data."
        fi
        if path_exists "$ssh_keys_marker"; then
            validate_root_state_file "$ssh_keys_marker"
            [[ "$(<"$ssh_keys_marker")" == installed \
                && "$(/usr/bin/wc -c < "$ssh_keys_marker" | tr -d '[:space:]')" == "10" ]] \
                || fail "Authorized-keys state marker contains unexpected data."
        fi
    fi

    if [[ "$state_is_managed" != true ]]; then
        if /usr/bin/getent passwd "$runtime_user" >/dev/null; then
            fail "Unexpected existing user: $runtime_user"
        fi
        if /usr/bin/getent group "$runtime_group" >/dev/null; then
            fail "Unexpected existing group: $runtime_group"
        fi
        path_exists "$runtime_home" && fail "Unexpected existing home: $runtime_home"

        for entry in \
            "$launcher_destination" \
            "$codex_destination" \
            "$claude_destination" \
            "$codex_root" \
            "$claude_key_destination" \
            "$claude_source_destination"; do
            path_exists "$entry" && fail "Unexpected existing managed path: $entry"
        done

        if /usr/bin/dpkg-query -W -f='${Status}' claude-code 2>/dev/null \
            | /bin/grep -q '^install ok installed$'; then
            fail "Unexpected existing claude-code package."
        fi

        if path_exists "$workspace_directory"; then
            [[ -d "$workspace_directory" && ! -L "$workspace_directory" ]] \
                || fail "Unexpected workspace path: $workspace_directory"
            if [[ -n "$(/usr/bin/find "$workspace_directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
                fail "Refusing a first install with non-empty $workspace_directory."
            fi
        fi
    else
        for entry in \
            "$launcher_destination" \
            "$codex_destination" \
            "$claude_destination" \
            "$claude_key_destination" \
            "$claude_source_destination"; do
            if path_exists "$entry" && [[ ! -f "$entry" && ! -L "$entry" ]]; then
                fail "Managed path is not a file: $entry"
            fi
        done
        if path_exists "$codex_home" && [[ ! -d "$codex_home" || -L "$codex_home" ]]; then
            fail "Managed Codex home is not a directory: $codex_home"
        fi
        if path_exists "$codex_root" && [[ ! -d "$codex_root" || -L "$codex_root" ]]; then
            fail "Managed Codex root is not a directory: $codex_root"
        fi
        if path_exists "$workspace_directory" && [[ ! -d "$workspace_directory" || -L "$workspace_directory" ]]; then
            fail "Managed workspace is not a directory: $workspace_directory"
        fi
        if path_exists "$runtime_home" && [[ ! -d "$runtime_home" || -L "$runtime_home" ]]; then
            fail "Managed worker home is not a directory: $runtime_home"
        fi
        validate_existing_runtime_user
        validate_existing_codex
        validate_existing_claude
    fi

    if ! path_exists "$ssh_keys_marker"; then
        [[ -f /root/.ssh/authorized_keys && ! -L /root/.ssh/authorized_keys \
            && -s /root/.ssh/authorized_keys ]] \
            || fail "Root authorized keys are unavailable for the worker account."
    else
        [[ -d "$runtime_home/.ssh" && ! -L "$runtime_home/.ssh" \
            && -f "$runtime_home/.ssh/authorized_keys" \
            && ! -L "$runtime_home/.ssh/authorized_keys" ]] \
            || fail "Managed worker authorized keys are missing or unsafe."
    fi
}

write_state_file() {
    local destination="$1"
    local content="$2"
    local temporary_file

    temporary_file="$(mktemp "$state_directory/.state.XXXXXX")"
    printf '%s\n' "$content" > "$temporary_file"
    /bin/chown root:root "$temporary_file"
    /bin/chmod 0644 "$temporary_file"
    /bin/mv -f -- "$temporary_file" "$destination"
}

initialize_identity() {
    local initial_hostname

    /usr/bin/install -d -o root -g root -m 0755 "$state_directory"
    if [[ ! -f "$version_file" ]]; then
        write_state_file "$version_file" "$installer_version"
    fi

    if path_exists "$worker_id_file"; then
        [[ -f "$worker_id_file" && ! -L "$worker_id_file" ]] \
            || fail "Invalid worker identity path: $worker_id_file"
        IFS= read -r worker_id < "$worker_id_file" \
            || fail "Unable to read worker identity."
    else
        worker_id="$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid)"
        write_state_file "$worker_id_file" "$worker_id"
    fi

    [[ "$worker_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
        || fail "Invalid persisted worker identity in $worker_id_file."
    [[ "$(/usr/bin/wc -c < "$worker_id_file" | tr -d '[:space:]')" == "37" ]] \
        || fail "Worker identity file contains unexpected data."

    worker_short_id="${worker_id%%-*}"
    if path_exists "$display_name_file"; then
        validate_root_state_file "$display_name_file"
        IFS= read -r worker_name < "$display_name_file" \
            || fail "Unable to read the managed display name."
    else
        initial_hostname="$(/bin/hostname)"
        if [[ "$initial_hostname" =~ ^terminal-relay-worker-([1-9][0-9]{0,5})$ ]]; then
            worker_name="Terminal Relay Worker ${BASH_REMATCH[1]}"
        else
            worker_name="Terminal Relay Worker $worker_short_id"
        fi
        write_state_file "$display_name_file" "$worker_name"
    fi
    is_valid_worker_name "$worker_name" \
        || fail "Invalid persisted worker display name in $display_name_file."
    [[ "$(/usr/bin/wc -c < "$display_name_file" | tr -d '[:space:]')" \
        == "$(( ${#worker_name} + 1 ))" ]] \
        || fail "Worker display name file contains unexpected data."
    worker_hostname="terminal-relay-worker-$worker_short_id"
}

validate_or_create_runtime_user() {
    local passwd_entry
    local user_home
    local user_shell
    local user_gid
    local expected_gid
    local user_was_created=false

    if /usr/bin/getent passwd "$runtime_user" >/dev/null; then
        passwd_entry="$(/usr/bin/getent passwd "$runtime_user")"
        IFS=: read -r _ _ _ user_gid _ user_home user_shell <<< "$passwd_entry"
        [[ "$user_home" == "$runtime_home" && "$user_shell" == "/bin/bash" ]] \
            || fail "Existing managed user has unexpected home or shell."
        /usr/bin/getent group "$runtime_group" >/dev/null \
            || fail "Existing managed user is missing its primary group."
        expected_gid="$(/usr/bin/getent group "$runtime_group" | /usr/bin/cut -d: -f3)"
        [[ "$user_gid" == "$expected_gid" ]] \
            || fail "Existing managed user has an unexpected primary group."
    else
        if ! /usr/bin/getent group "$runtime_group" >/dev/null; then
            /usr/sbin/groupadd "$runtime_group"
        fi
        /usr/sbin/useradd \
            --create-home \
            --home-dir "$runtime_home" \
            --shell /bin/bash \
            --gid "$runtime_group" \
            "$runtime_user"
        user_was_created=true
    fi

    /usr/bin/passwd --lock "$runtime_user" >/dev/null
    [[ "$(/usr/bin/passwd -S "$runtime_user" | /usr/bin/awk '{print $2}')" == "L" ]] \
        || fail "Unable to lock the $runtime_user password."
    /bin/chown "$runtime_user:$runtime_group" "$runtime_home"
    /bin/chmod 0750 "$runtime_home"

    if [[ ! -f "$ssh_keys_marker" ]]; then
        [[ -f /root/.ssh/authorized_keys && ! -L /root/.ssh/authorized_keys \
            && -s /root/.ssh/authorized_keys ]] \
            || fail "Root authorized keys are unavailable for the worker account."
        /usr/bin/install -d -o "$runtime_user" -g "$runtime_group" -m 0700 "$runtime_home/.ssh"
        /usr/bin/install -o "$runtime_user" -g "$runtime_group" -m 0600 \
            /root/.ssh/authorized_keys "$runtime_home/.ssh/authorized_keys"
        write_state_file "$ssh_keys_marker" installed
    elif [[ ! -f "$runtime_home/.ssh/authorized_keys" || -L "$runtime_home/.ssh/authorized_keys" ]]; then
        fail "Managed worker authorized keys are missing or unsafe."
    fi

    /bin/chown "$runtime_user:$runtime_group" "$runtime_home/.ssh" "$runtime_home/.ssh/authorized_keys"
    /bin/chmod 0700 "$runtime_home/.ssh"
    /bin/chmod 0600 "$runtime_home/.ssh/authorized_keys"
    if [[ "$user_was_created" == true ]]; then
        log "Created locked $runtime_user login user and copied the bootstrap SSH keys."
    fi
}

run_as_worker() {
    /usr/sbin/runuser -u "$runtime_user" -- \
        env \
            HOME="$runtime_home" \
            USER="$runtime_user" \
            LOGNAME="$runtime_user" \
            SHELL=/bin/bash \
            PATH=/usr/local/bin:/usr/bin:/bin \
            "$@"
}

install_dependencies() {
    log "Installing Ubuntu runtime dependencies."
    export DEBIAN_FRONTEND=noninteractive
    /usr/bin/apt-get update
    /usr/bin/apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        gnupg \
        git \
        grep \
        gzip \
        hostname \
        mawk \
        openssh-client \
        procps \
        python3 \
        sed \
        tar \
        tmux \
        util-linux
}

install_codex() {
    local installer="$temporary_directory/codex-install.sh"
    local current_rollback_index
    local command_rollback_index

    log "Installing official Codex standalone release: $CODEX_RELEASE"
    /usr/bin/install -d -o root -g root -m 0755 "$codex_root" "$codex_home"
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL -o "$installer" "$codex_installer_url"
    /bin/chmod 0700 "$installer"
    prepare_managed_rollback "$codex_current_link" false
    current_rollback_index=$((${#rollback_destinations[@]} - 1))
    prepare_managed_rollback "$codex_destination" false
    command_rollback_index=$((${#rollback_destinations[@]} - 1))
    env \
        CODEX_HOME="$codex_home" \
        CODEX_INSTALL_DIR=/usr/bin \
        CODEX_NON_INTERACTIVE=1 \
        CODEX_RELEASE="$CODEX_RELEASE" \
        /bin/sh "$installer"
    [[ -x "$codex_destination" ]] || fail "Codex installer did not create $codex_destination."
    discard_rollback_if_unchanged "$command_rollback_index"
    discard_rollback_if_unchanged "$current_rollback_index"
    announce_rollback_backup "$current_rollback_index"
    announce_rollback_backup "$command_rollback_index"
    /bin/chown -R root:root "$codex_root"
    /usr/bin/find "$codex_root" -type d -exec /bin/chmod a+rx {} +
    /usr/bin/find "$codex_root" -type f -exec /bin/chmod a+r {} +
}

install_claude() {
    local key_file="$temporary_directory/claude-code.asc"
    local source_file="$temporary_directory/claude-code.list"
    local actual_fingerprint
    local -a apt_install_arguments=(-y --no-install-recommends)

    log "Installing Claude Code from the official signed stable apt channel."
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL -o "$key_file" "$claude_key_url"
    actual_fingerprint="$(/usr/bin/gpg --batch --show-keys --with-colons "$key_file" \
        | /usr/bin/awk -F: '$1 == "fpr" { print toupper($10); exit }')"
    [[ "$actual_fingerprint" == "$claude_key_fingerprint" ]] \
        || fail "Claude signing key fingerprint mismatch."
    printf '%s\n' "$claude_repository" > "$source_file"

    install_managed_file "$key_file" "$claude_key_destination" 644
    install_managed_file "$source_file" "$claude_source_destination" 644
    /usr/bin/apt-get update
    if /usr/bin/dpkg-query -W -f='${Status}' claude-code 2>/dev/null \
        | /bin/grep -q '^install ok installed$' \
        && [[ ! -x "$claude_destination" ]]; then
        apt_install_arguments+=(--reinstall)
        log "Repairing the installed Claude Code package because its command is unavailable."
    fi
    /usr/bin/apt-get install "${apt_install_arguments[@]}" claude-code
    [[ -x "$claude_destination" ]] || fail "Claude package did not create $claude_destination."
    /usr/bin/dpkg-query -S "$claude_destination" | /bin/grep -q '^claude-code:' \
        || fail "$claude_destination is not owned by the claude-code package."
}

prepare_worker_guidance() {
    local source="$1"
    local destination="$2"
    local parent

    parent="$(dirname "$destination")"
    if path_exists "$parent" && [[ ! -d "$parent" || -L "$parent" ]]; then
        fail "Worker guidance parent is not a safe directory: $parent"
    fi
    if path_exists "$destination" && [[ ! -f "$destination" || -L "$destination" ]]; then
        fail "Worker guidance destination is not a safe file: $destination"
    fi
    if [[ -f "$destination" ]] \
        && /usr/bin/cmp -s -- "$source" "$destination" \
        && [[ "$(/usr/bin/stat -c '%U:%G:%a' "$destination")" == "$runtime_user:$runtime_group:644" ]]; then
        return
    fi

    prepare_managed_rollback "$destination"
    if path_exists "$destination"; then
        /bin/rm -f -- "$destination"
    fi
}

install_runtime_files() {
    /usr/bin/install -d -o "$runtime_user" -g "$runtime_group" -m 0750 "$workspace_directory"
    install_managed_file "$launcher_source" "$launcher_destination" 755
    prepare_worker_guidance "$worker_config_directory/AGENTS.md" "$runtime_home/AGENTS.md"
    prepare_worker_guidance "$worker_config_directory/CLAUDE.md" "$runtime_home/CLAUDE.md"
    prepare_worker_guidance "$worker_config_directory/AGENTS.md" "$runtime_home/.codex/AGENTS.md"
    prepare_worker_guidance "$worker_config_directory/CLAUDE.md" "$runtime_home/.claude/CLAUDE.md"
    run_as_worker /bin/bash "$worker_config_directory/install.sh"
    /bin/chown "$runtime_user:$runtime_group" \
        "$runtime_home/AGENTS.md" \
        "$runtime_home/CLAUDE.md" \
        "$runtime_home/.codex/AGENTS.md" \
        "$runtime_home/.claude/CLAUDE.md"
    /bin/chmod 0644 \
        "$runtime_home/AGENTS.md" \
        "$runtime_home/CLAUDE.md" \
        "$runtime_home/.codex/AGENTS.md" \
        "$runtime_home/.claude/CLAUDE.md"

}

set_worker_hostname() {
    local hostname_source="$temporary_directory/hostname"
    local live_hostname

    live_hostname="$(/bin/hostname)"
    if [[ "$live_hostname" == "$worker_hostname" \
        && -f /etc/hostname \
        && "$(< /etc/hostname)" == "$worker_hostname" ]]; then
        return
    fi

    original_hostname="$live_hostname"
    printf '%s\n' "$worker_hostname" > "$hostname_source"
    install_managed_file "$hostname_source" /etc/hostname 644

    if [[ "$live_hostname" != "$worker_hostname" ]]; then
        if [[ -d /run/systemd/system ]] \
            && /usr/bin/hostnamectl set-hostname "$worker_hostname"; then
            log "Set hostname to $worker_hostname."
        else
            /bin/hostname "$worker_hostname" 2>/dev/null || true
            log "Set hostname to $worker_hostname without systemd."
        fi

        if [[ "$(/bin/hostname)" == "$worker_hostname" ]]; then
            hostname_was_changed=true
        else
            fail "Unable to set the live hostname to $worker_hostname."
        fi
    fi

    [[ -f /etc/hostname && "$(< /etc/hostname)" == "$worker_hostname" ]] \
        || fail "Unable to persist hostname $worker_hostname."
}

verify_readiness() {
    local workspace_probe
    local required_command
    local login_command_path

    log "Verifying worker readiness."
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$workspace_directory")" == "$runtime_user:$runtime_group:750" ]] \
        || fail "Unexpected ownership or mode on $workspace_directory."
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$launcher_destination")" == "root:root:755" ]] \
        || fail "Unexpected ownership or mode on $launcher_destination."
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$runtime_home/.ssh")" == "$runtime_user:$runtime_group:700" ]] \
        || fail "Unexpected ownership or mode on the worker SSH directory."
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$runtime_home/.ssh/authorized_keys")" == "$runtime_user:$runtime_group:600" ]] \
        || fail "Unexpected ownership or mode on worker authorized keys."

    for required_command in git ssh awk df nproc flock tmux python3 codex claude terminal-relay-session; do
        login_command_path="$(run_as_worker /bin/bash -lc \
            "cd \"\$HOME\" && command -v $required_command")" \
            || fail "$required_command is unavailable in the worker login shell."
        [[ "$login_command_path" == /* && "$login_command_path" != *$'\n'* ]] \
            || fail "$required_command resolved to an invalid login-shell path."
    done
    [[ "$(run_as_worker /bin/bash -lc "cd \"\$HOME\" && command -v codex")" == "$codex_destination" ]] \
        || fail "Codex does not resolve to $codex_destination in the worker login shell."
    [[ "$(run_as_worker /bin/bash -lc "cd \"\$HOME\" && command -v claude")" == "$claude_destination" ]] \
        || fail "Claude does not resolve to $claude_destination in the worker login shell."
    run_as_worker "$codex_destination" --version >/dev/null
    run_as_worker "$claude_destination" --version >/dev/null
    run_as_worker /usr/bin/git --version >/dev/null
    run_as_worker /usr/bin/ssh -V >/dev/null 2>&1
    run_as_worker /usr/bin/nproc >/dev/null
    run_as_worker /usr/bin/python3 --version >/dev/null
    run_as_worker /usr/bin/awk 'NR == 1 { found = 1 } END { exit !found }' /proc/stat
    run_as_worker /usr/bin/awk \
        '/^MemTotal:/ { found = 1 } END { exit !found }' /proc/meminfo
    run_as_worker /bin/df -Pk "$workspace_directory" >/dev/null

    workspace_probe="$(run_as_worker /usr/bin/mktemp \
        "$workspace_directory/.terminal-relay-write.XXXXXX")"
    [[ "$workspace_probe" == "$workspace_directory"/.terminal-relay-write.* ]] \
        || fail "Workspace write probe returned an unexpected path."
    /bin/rm -f -- "$workspace_probe"

}

main() {
    [[ "$EUID" -eq 0 ]] || fail "Run this installer as root."
    [[ "$#" -eq 0 ]] || fail "This installer does not accept arguments."
    validate_source_bundle
    validate_platform
    validate_managed_state

    temporary_directory="$(mktemp -d /tmp/terminal-relay-install.XXXXXX)"
    installation_started=true
    initialize_identity
    validate_or_create_runtime_user
    /usr/bin/install -d -o "$runtime_user" -g "$runtime_group" -m 0750 "$workspace_directory"
    install_dependencies
    install_codex
    install_claude
    install_runtime_files
    set_worker_hostname
    verify_readiness

    installation_succeeded=true
    printf '%s\n' 'TERMINAL_RELAY_RESULT_V1'
    printf 'id=%s\n' "$worker_id"
    printf 'name=%s\n' "$worker_name"
    printf '%s\n' 'TERMINAL_RELAY_RESULT_END'
}

main "$@"
