#!/bin/bash
set -euo pipefail

readonly APP_PATH="/Applications/Terminal Relay.app"
readonly APP_BUNDLE_ID="com.mpieras.TerminalRelay"
readonly RUNTIME_USER="terminal-relay"

usage() {
    cat <<'EOF'
Usage: ./Scripts/bootstrap-worker.sh [--identity PATH] [--port N] root@host

Provision a fresh Ubuntu 24.04 amd64 worker, authenticate Codex and Claude,
and register it in Terminal Relay.

Options:
  --identity PATH  SSH private key to use and store in the worker profile
  --port N         SSH port (otherwise use OpenSSH configuration or port 22)
  -h, --help       Show this help
EOF
}

die() { echo "bootstrap-worker: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

marker_value() {
    marker_name="$1"
    marker_file="$2"
    marker_count=$(/usr/bin/awk -F= -v key="$marker_name" '$1 == key { count++ } END { print count + 0 }' "$marker_file")
    [[ "$marker_count" -eq 1 ]] || die "invalid remote output: expected exactly one $marker_name marker"
    /usr/bin/awk -v prefix="$marker_name=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' "$marker_file"
}

ssh_route_signature() {
    /usr/bin/awk '
        $1 == "hostname" ||
        $1 == "port" ||
        $1 == "proxycommand" ||
        $1 == "proxyjump" ||
        $1 == "hostkeyalias" ||
        $1 == "identityagent" ||
        $1 == "identityfile" ||
        $1 == "identitiesonly" ||
        $1 == "stricthostkeychecking" ||
        $1 == "userknownhostsfile" { print }
    '
}

base64url() {
    printf '%s' "$1" | /usr/bin/base64 | /usr/bin/tr -d '\r\n' | /usr/bin/tr '+/' '-_' | /usr/bin/sed 's/=*$//'
}

parse_install_result() {
    local result_file="$1"
    local state="before"
    local line
    local saw_id=false
    local saw_name=false

    worker_id=""
    worker_name=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$state" in
            before)
                if [[ "$line" == "TERMINAL_RELAY_RESULT_V1" ]]; then
                    state="inside"
                elif [[ "$line" == "TERMINAL_RELAY_RESULT_END" ]]; then
                    die "invalid remote output: result end preceded its start"
                fi
                ;;
            inside)
                case "$line" in
                    id=*)
                        [[ "$saw_id" == false ]] || die "invalid remote output: duplicate worker id"
                        worker_id="${line#id=}"
                        saw_id=true
                        ;;
                    name=*)
                        [[ "$saw_name" == false ]] || die "invalid remote output: duplicate worker name"
                        worker_name="${line#name=}"
                        saw_name=true
                        ;;
                    TERMINAL_RELAY_RESULT_END)
                        [[ "$saw_id" == true && "$saw_name" == true ]] \
                            || die "invalid remote output: incomplete worker result"
                        state="after"
                        ;;
                    *) die "invalid remote output inside the worker result block" ;;
                esac
                ;;
            after)
                [[ "$line" != "TERMINAL_RELAY_RESULT_V1" \
                    && "$line" != "TERMINAL_RELAY_RESULT_END" ]] \
                    || die "invalid remote output: duplicate result block"
                ;;
        esac
    done < "$result_file"

    [[ "$state" == "after" ]] || die "invalid remote output: missing worker result block"
}

identity_path=""
port=""
target=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --identity)
            [[ "$#" -ge 2 ]] || die "--identity requires a path"
            identity_path="$2"
            shift 2
            ;;
        --port)
            [[ "$#" -ge 2 ]] || die "--port requires a value"
            port="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            [[ "$#" -eq 1 ]] || die "expected exactly one root@host target"
            target="$1"
            shift
            ;;
        -*) die "unknown option: $1" ;;
        *)
            [[ -z "$target" ]] || die "expected exactly one root@host target"
            target="$1"
            shift
            ;;
    esac
done

[[ -n "$target" ]] || { usage >&2; exit 2; }
if [[ -n "$port" ]]; then
    if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( 10#$port > 65535 )); then
        die "SSH port must be an integer from 1 to 65535"
    fi
fi
[[ "$target" == root@* ]] || die "V1 requires an SSH target in the form root@host"
host="${target#root@}"
[[ -n "$host" && "$host" != *"@"* && "$host" != *$'\n'* && "$host" != *$'\r'* ]] || die "invalid SSH host"
[[ ${#host} -le 253 \
    && "$host" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])$ \
    && "$host" != *".."* ]] || die "SSH host contains unsupported characters"

if [[ -n "$identity_path" ]]; then
    if printf '%s' "$identity_path" | /usr/bin/grep -q '[[:cntrl:]]'; then
        die "invalid identity path"
    fi
    [[ -f "$identity_path" && -r "$identity_path" ]] || die "SSH identity is not a readable file: $identity_path"
    identity_directory="$(cd "$(dirname "$identity_path")" && pwd -P)"
    identity_path="$identity_directory/$(basename "$identity_path")"
    identity_path_bytes=$(printf '%s' "$identity_path" | /usr/bin/wc -c | /usr/bin/tr -d '[:space:]')
    [[ "$identity_path_bytes" =~ ^[0-9]+$ && "$identity_path_bytes" -le 1024 ]] \
        || die "SSH identity path is too long"
fi

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || die "this orchestrator must run on macOS"
[[ -d "$APP_PATH" ]] || die "Terminal Relay is not installed at $APP_PATH"
installed_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[[ "$installed_bundle_id" == "$APP_BUNDLE_ID" ]] || die "the installed Terminal Relay bundle identifier is unexpected"
require_command gh
require_command ssh
require_command ssh-keygen
[[ -x /usr/bin/tar \
    && -x /usr/bin/open \
    && -x /usr/bin/base64 \
    && -x /usr/bin/openssl ]] || die "required macOS system tools are unavailable"
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated; run 'gh auth login' first"

identity_fingerprint=""
if [[ -n "$identity_path" ]]; then
    identity_fingerprint=$(/usr/bin/ssh-keygen -lf "$identity_path" -E sha256 2>/dev/null \
        | /usr/bin/awk 'NR == 1 { print $2 }') \
        || die "could not read the SSH identity fingerprint"
    [[ "$identity_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] \
        || die "the SSH identity fingerprint is invalid"
fi

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
server_directory="$repository_root/Server"
for payload_path in install-worker.sh terminal-relay-session worker-config/install.sh worker-config/AGENTS.md worker-config/CLAUDE.md; do
    [[ -f "$server_directory/$payload_path" ]] || die "missing bootstrap payload: Server/$payload_path"
done

ssh_options=(-o ControlMaster=no -o ControlPath=none)
[[ -z "$port" ]] || ssh_options+=(-p "$port")
[[ -z "$identity_path" ]] || ssh_options+=(-o IdentitiesOnly=yes -i "$identity_path")
ssh_config=$(/usr/bin/ssh "${ssh_options[@]}" -G "$target" 2>/dev/null) || die "could not resolve SSH configuration for $target"
resolved_host=$(printf '%s\n' "$ssh_config" | /usr/bin/awk '$1 == "hostname" { print $2; exit }')
resolved_port=$(printf '%s\n' "$ssh_config" | /usr/bin/awk '$1 == "port" { print $2; exit }')
resolved_user=$(printf '%s\n' "$ssh_config" | /usr/bin/awk '$1 == "user" { print $2; exit }')
[[ -n "$resolved_host" && "$resolved_port" =~ ^[0-9]+$ && "$resolved_user" == "root" ]] || die "SSH configuration did not resolve to a root destination"
(( 10#$resolved_port >= 1 && 10#$resolved_port <= 65535 )) || die "SSH configuration resolved an invalid port"

runtime_target="$RUNTIME_USER@$host"
runtime_ssh_config=$(/usr/bin/ssh "${ssh_options[@]}" -G "$runtime_target" 2>/dev/null) \
    || die "could not resolve SSH configuration for $runtime_target"
runtime_resolved_user=$(printf '%s\n' "$runtime_ssh_config" | /usr/bin/awk '$1 == "user" { print $2; exit }')
[[ "$runtime_resolved_user" == "$RUNTIME_USER" ]] \
    || die "SSH configuration did not resolve to the $RUNTIME_USER user"
root_route_signature=$(printf '%s\n' "$ssh_config" | ssh_route_signature)
runtime_route_signature=$(printf '%s\n' "$runtime_ssh_config" | ssh_route_signature)
[[ "$root_route_signature" == "$runtime_route_signature" ]] \
    || die "SSH configuration resolves root and $RUNTIME_USER through different routes; use explicit --identity/--port settings or align the SSH config first"

temporary_root="${TMPDIR:-/tmp}"
[[ "$temporary_root" == /* && -d "$temporary_root" ]] || die "invalid temporary directory root: $temporary_root"
temporary_root="$(cd "$temporary_root" && pwd -P)"
temporary_directory=$(/usr/bin/mktemp -d "$temporary_root/terminal-relay-bootstrap.XXXXXX")
registration_token_file=""
registration_handoff_dispatched=false
cleanup() {
    cleanup_exit_code=$?
    trap - EXIT
    if [[ -n "${temporary_directory:-}" && -d "$temporary_directory" ]]; then
        temporary_parent="$(dirname "$temporary_directory")"
        temporary_name="$(basename "$temporary_directory")"
        if [[ "$temporary_parent" == "$temporary_root" && "$temporary_name" == terminal-relay-bootstrap.* ]]; then
            /bin/rm -rf -- "$temporary_directory"
        else
            echo "Refusing to clean unexpected temporary path: $temporary_directory" >&2
            cleanup_exit_code=1
        fi
    fi
    if [[ "$registration_handoff_dispatched" != true \
        && -n "${registration_token_file:-}" \
        && -f "$registration_token_file" \
        && ! -L "$registration_token_file" ]]; then
        /bin/rm -f -- "$registration_token_file"
    fi
    exit "$cleanup_exit_code"
}
trap cleanup EXIT

preflight_file="$temporary_directory/preflight"
preflight_ssh_log="$temporary_directory/preflight-ssh.log"
/usr/bin/ssh -vv "${ssh_options[@]}" "$target" '/bin/bash -s' \
    >"$preflight_file" 2>"$preflight_ssh_log" <<'REMOTE_PREFLIGHT'
set -euo pipefail
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "root access is required" >&2; exit 1; }
[[ -r /etc/os-release ]] || { echo "missing /etc/os-release" >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || { echo "Ubuntu 24.04 is required" >&2; exit 1; }
architecture=$(uname -m)
[[ "$architecture" == "x86_64" || "$architecture" == "amd64" ]] || { echo "amd64 is required" >&2; exit 1; }
memory_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
[[ "$memory_kib" =~ ^[0-9]+$ && "$memory_kib" -ge 3900000 ]] || { echo "at least 4 GB RAM is required" >&2; exit 1; }
printf '%s\n' 'TERMINAL_RELAY_PREFLIGHT_V1'
printf 'hostname=%s\n' "$(hostname)"
printf 'os=%s\n' 'Ubuntu 24.04'
printf 'architecture=%s\n' 'amd64'
printf 'memory_kib=%s\n' "$memory_kib"
printf '%s\n' 'TERMINAL_RELAY_PREFLIGHT_END'
REMOTE_PREFLIGHT

[[ "$(/usr/bin/sed -n '1p' "$preflight_file")" == "TERMINAL_RELAY_PREFLIGHT_V1" ]] || die "invalid remote preflight output"
[[ "$(/usr/bin/tail -n 1 "$preflight_file")" == "TERMINAL_RELAY_PREFLIGHT_END" ]] || die "incomplete remote preflight output"
remote_hostname=$(marker_value hostname "$preflight_file")
remote_os=$(marker_value os "$preflight_file")
remote_architecture=$(marker_value architecture "$preflight_file")
remote_memory_kib=$(marker_value memory_kib "$preflight_file")
host_key_fingerprint=$(/usr/bin/awk '
    /Server host key:/ {
        for (field_index = 1; field_index <= NF; field_index++) {
            if ($field_index ~ /^SHA256:/) fingerprint = $field_index
        }
    }
    END {
        sub(/\r$/, "", fingerprint)
        print fingerprint
    }
' "$preflight_ssh_log")
accepted_identity_fingerprint=$(/usr/bin/awk '
    /Server accepts key:/ {
        for (field_index = 1; field_index <= NF; field_index++) {
            if ($field_index ~ /^SHA256:/) fingerprint = $field_index
        }
    }
    END {
        sub(/\r$/, "", fingerprint)
        print fingerprint
    }
' "$preflight_ssh_log")
[[ "$remote_hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || die "remote hostname is invalid"
[[ "$remote_os" == "Ubuntu 24.04" && "$remote_architecture" == "amd64" ]] || die "remote platform changed during preflight"
[[ "$remote_memory_kib" =~ ^[0-9]+$ && "$remote_memory_kib" -ge 3900000 ]] || die "remote memory check failed"
[[ "$host_key_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || die "remote host-key fingerprint is invalid"
if [[ -n "$identity_fingerprint" && "$accepted_identity_fingerprint" != "$identity_fingerprint" ]]; then
    die "SSH did not authenticate with the requested --identity key"
fi

echo "Terminal Relay worker bootstrap"
echo "  SSH target:       $target"
echo "  Resolved target:  $resolved_user@$resolved_host:$resolved_port"
echo "  Host key:         $host_key_fingerprint"
echo "  Current hostname: $remote_hostname"
echo "  Platform:         $remote_os ($remote_architecture)"
echo "  Memory:           $remote_memory_kib KiB"
echo "  Runtime user:     $RUNTIME_USER"
[[ -z "$identity_path" ]] || echo "  Identity:         $identity_path"
echo
echo "This will provision the exact server above and preserve root SSH access."
printf 'Continue? [y/N] ' >/dev/tty
IFS= read -r confirmation </dev/tty || die "confirmation was not provided"
case "$confirmation" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac

result_file="$temporary_directory/install-result"
/usr/bin/tar --no-xattrs -C "$server_directory" -cf - install-worker.sh terminal-relay-session worker-config | \
    /usr/bin/ssh "${ssh_options[@]}" "$target" '
set -eu
temporary_root=${TMPDIR:-/tmp}
case "$temporary_root" in /*) ;; *) echo "invalid remote temporary root" >&2; exit 1 ;; esac
[ -d "$temporary_root" ] || { echo "remote temporary root does not exist" >&2; exit 1; }
temporary_root=$(cd "$temporary_root" && pwd -P)
temporary_directory=$(mktemp -d "$temporary_root/terminal-relay-worker-install.XXXXXX")
cleanup() {
    code=$?
    trap - 0
    parent=$(dirname "$temporary_directory")
    name=$(basename "$temporary_directory")
    if [ "$parent" = "$temporary_root" ]; then
        case "$name" in terminal-relay-worker-install.*) rm -rf -- "$temporary_directory" ;; *) code=1 ;; esac
    else
        code=1
    fi
    exit "$code"
}
trap cleanup 0
chmod 0755 "$temporary_directory"
tar --no-same-owner --no-same-permissions -xf - -C "$temporary_directory"
/bin/chown -R root:root "$temporary_directory"
/bin/bash "$temporary_directory/install-worker.sh"
' | /usr/bin/tee "$result_file"

parse_install_result "$result_file"
[[ "$worker_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die "installer returned an invalid worker UUID"
short_id="${worker_id%%-*}"
[[ "$worker_name" == "Terminal Relay Worker $short_id" \
    || "$worker_name" =~ ^Terminal\ Relay\ Worker\ [1-9][0-9]{0,5}$ ]] \
    || die "installer returned an invalid worker name"

if ! /usr/bin/ssh "${ssh_options[@]}" "$runtime_target" '/usr/bin/codex login status >/dev/null 2>&1'; then
    echo "Codex authentication is required. Follow the device authorization instructions."
    /usr/bin/ssh -tt "${ssh_options[@]}" "$runtime_target" '/usr/bin/codex login --device-auth'
fi
/usr/bin/ssh "${ssh_options[@]}" "$runtime_target" '/usr/bin/codex login status >/dev/null 2>&1' || die "Codex authentication is still missing"

claude_is_authenticated() {
    /usr/bin/ssh "${ssh_options[@]}" "$runtime_target" \
        '/usr/bin/claude auth status --json 2>/dev/null | /bin/grep -Eq '\''"loggedIn"[[:space:]]*:[[:space:]]*true'\'''
}

if ! claude_is_authenticated; then
    echo "Claude authentication is required. Follow the authorization instructions."
    /usr/bin/ssh -tt "${ssh_options[@]}" "$runtime_target" '/usr/bin/claude auth login'
fi
claude_is_authenticated || die "Claude authentication is still missing"

/usr/bin/ssh "${ssh_options[@]}" "$runtime_target" '
set -eu
test "$(id -un)" = terminal-relay
test "$HOME" = /home/terminal-relay
test -d /workspace && test -w /workspace
test -x /usr/local/bin/terminal-relay-session
test -x /usr/bin/codex && test -x /usr/bin/claude
test -r /proc/stat && test -r /proc/meminfo
/usr/local/bin/terminal-relay-session status >/dev/null
runtime_directory="/run/user/$(id -u)/terminal-relay"
/usr/bin/flock "$runtime_directory/codex.control.lock" /bin/sleep 3 &
lock_holder_pid=$!
/bin/sleep 1
set +e
/usr/bin/timeout 1 /usr/local/bin/terminal-relay-session status >/dev/null
lock_result=$?
set -e
wait "$lock_holder_pid"
test "$lock_result" -eq 124
/usr/local/bin/terminal-relay-session status >/dev/null
'

registration_proof=$(/usr/bin/openssl rand -hex 32) \
    || die "could not generate a worker registration proof"
[[ "$registration_proof" =~ ^[0-9a-f]{64}$ ]] \
    || die "generated worker registration proof is invalid"
registration_parent="${HOME:?HOME must be set}/Library/Application Support/Terminal Relay"
registration_directory="$registration_parent/Worker Registrations"
if [[ -e "$registration_parent" || -L "$registration_parent" ]]; then
    [[ -d "$registration_parent" && ! -L "$registration_parent" ]] \
        || die "worker registration parent is not a safe directory"
else
    /bin/mkdir -m 0700 "$registration_parent"
fi
if [[ -e "$registration_directory" || -L "$registration_directory" ]]; then
    [[ -d "$registration_directory" && ! -L "$registration_directory" ]] \
        || die "worker registration path is not a safe directory"
else
    /bin/mkdir -m 0700 "$registration_directory"
fi
/bin/chmod 0700 "$registration_directory"
registration_token_file="$registration_directory/$worker_id.token"
registration_token_temporary="$registration_directory/.$worker_id.token.$$"
(
    umask 077
    printf '%s\n' "$registration_proof" > "$registration_token_temporary"
)
/bin/chmod 0600 "$registration_token_temporary"
/bin/mv -f -- "$registration_token_temporary" "$registration_token_file"

registration_url="terminal-relay://register-worker?v=1&id=$worker_id&name=$(base64url "$worker_name")&host=$(base64url "$host")&username=$(base64url "$RUNTIME_USER")&identity=$(base64url "$identity_path")&port=$resolved_port&proof=$registration_proof"
/usr/bin/open -b "$APP_BUNDLE_ID" "$registration_url" || die "Terminal Relay did not accept the registration URL"
registration_handoff_dispatched=true

echo
echo "$worker_name is ready and registered."
echo "SSH: $runtime_target (port $resolved_port)"
echo "Workspace: /workspace"
