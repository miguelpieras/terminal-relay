#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly SERVER_DIRECTORY="$REPOSITORY_ROOT/Server"
readonly BASELINE_FILE="${TERMINAL_RELAY_BASELINE_FILE:-$SERVER_DIRECTORY/worker-baseline.local.env}"
readonly HOST_INSTALLER="$SERVER_DIRECTORY/install-worker-host.sh"
readonly SESSION_HELPER_SOURCE="$SERVER_DIRECTORY/terminal-relay-session"
readonly CHAT_SOURCE="$SERVER_DIRECTORY/terminal-relay-chat"
readonly MCP_SOURCE="$SERVER_DIRECTORY/terminal-relay-mcp"
readonly CLAUDE_SESSIONS_SOURCE="$SERVER_DIRECTORY/terminal-relay-claude-sessions"
readonly CLAUDE_REQUIREMENTS_SOURCE="$SERVER_DIRECTORY/claude-agent-sdk-requirements.txt"
readonly RUNTIME_UPDATER_SOURCE="$SERVER_DIRECTORY/terminal-relay-runtime-update"
readonly RUNTIME_PUBLIC_KEY_SOURCE="$SERVER_DIRECTORY/terminal-relay-runtime-update.pub"
readonly STABLE_RUNTIME_PREFLIGHT="$SCRIPT_DIRECTORY/verify-published-worker-runtime.sh"
readonly NODE_EXPORTER_TEMPLATE="$SERVER_DIRECTORY/node-exporter.service.template"
readonly SECURITY_METRICS_COLLECTOR="$SERVER_DIRECTORY/terminal-relay-security-metrics"
readonly SECURITY_METRICS_SERVICE="$SERVER_DIRECTORY/terminal-relay-security-metrics.service"
readonly SECURITY_METRICS_TIMER="$SERVER_DIRECTORY/terminal-relay-security-metrics.timer"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIRECTORY/bootstrap-worker.sh"
readonly SSH_CONFIG="$HOME/.ssh/config"
readonly TAILSCALE_KEYCHAIN_SERVICE="com.mpieras.TerminalRelay.worker-lifecycle.tailscale-oauth"
readonly TAILSCALE_CLIENT_ID_ACCOUNT="client-id"
readonly TAILSCALE_CLIENT_SECRET_ACCOUNT="client-secret"
readonly TAILSCALE_TOKEN_URL="https://api.tailscale.com/api/v2/oauth/token"
readonly TAILSCALE_API_ROOT="https://api.tailscale.com/api/v2"
TAILSCALE_CLI="$(command -v tailscale 2>/dev/null || true)"
readonly TAILSCALE_CLI

die() {
    printf 'manage-worker: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[manage-worker] %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  ./Scripts/manage-worker.sh configure
  ./Scripts/manage-worker.sh provision [--yes] N
  ./Scripts/manage-worker.sh adopt [--yes] N root@TAILSCALE_IP
  ./Scripts/manage-worker.sh reconcile N|all
  ./Scripts/manage-worker.sh verify N|all
  ./Scripts/manage-worker.sh retire N

Examples:
  ./Scripts/manage-worker.sh provision 3
  ./Scripts/manage-worker.sh adopt 3 root@100.64.0.3
  ./Scripts/manage-worker.sh reconcile all
  ./Scripts/manage-worker.sh verify all

`configure` stores the project-scoped Tailscale OAuth client in macOS Keychain
and creates the `terminal-relay` hcloud context if it is absent. Provisioning is
then one command. It creates the Hetzner VM, enrolls its unique tagged Tailscale
identity, applies the shared host baseline, authenticates Codex and Claude when
needed, and registers the worker in Terminal Relay.

`adopt` assigns a numeric identity to an existing tagged Terminal Relay worker
without replacing its UUID or project data, then applies the same baseline.
EOF
}

load_baseline() {
    local variable

    [[ -f "$BASELINE_FILE" && ! -L "$BASELINE_FILE" ]] \
        || die "missing local baseline: copy Server/worker-baseline.example.env to Server/worker-baseline.local.env"
    # shellcheck disable=SC1090
    . "$BASELINE_FILE"

    for variable in \
        TERMINAL_RELAY_PROVIDER_PROJECT_ID \
        TERMINAL_RELAY_PROVIDER_FIREWALL_ID \
        TERMINAL_RELAY_MONITOR_IPV4 \
        TERMINAL_RELAY_MONITOR_IPV6 \
        TERMINAL_RELAY_DESKTOP_IPV4 \
        TERMINAL_RELAY_DESKTOP_IPV6 \
        TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT \
        TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY; do
        [[ -n "${!variable:-}" && "${!variable}" != REPLACE_ME ]] \
            || die "local baseline value is not configured: $variable"
    done

    readonly OPERATOR_PRIVATE_KEY="${TERMINAL_RELAY_OPERATOR_PRIVATE_KEY:-${HOME:?HOME must be set}/.ssh/terminal-relay-operator}"
    readonly OPERATOR_PUBLIC_KEY="$OPERATOR_PRIVATE_KEY.pub"
}

temporary_directory=""
temporary_root_resolved=""
HOST_BUNDLE_RESULT=""
cleanup() {
    local exit_code=$?
    local parent
    local name

    trap - EXIT
    if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
        parent="$(dirname "$temporary_directory")"
        name="$(basename "$temporary_directory")"
        if [[ "$parent" == "$temporary_root_resolved" ]] \
            && [[ "$name" == terminal-relay-worker.* ]]; then
            /bin/rm -rf -- "$temporary_directory"
        else
            printf 'manage-worker: refusing to clean unexpected temporary path: %s\n' \
                "$temporary_directory" >&2
            exit_code=1
        fi
    fi
    exit "$exit_code"
}
trap cleanup EXIT

make_temporary_directory() {
    local temporary_root="${TMPDIR:-/tmp}"

    [[ "$temporary_root" == /* && -d "$temporary_root" ]] \
        || die "invalid temporary directory root"
    temporary_root_resolved="$(cd "$temporary_root" && pwd -P)"
    temporary_directory="$(/usr/bin/mktemp -d "$temporary_root_resolved/terminal-relay-worker.XXXXXX")"
    /bin/chmod 0700 "$temporary_directory"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

validate_local_prerequisites() {
    local fingerprint
    local command

    [[ "$(/usr/bin/uname -s)" == Darwin ]] || die "this command must run on macOS"
    for command in curl hcloud jq security ssh ssh-keygen tar tailscale; do
        require_command "$command"
    done
    [[ -n "$TAILSCALE_CLI" && -x "$TAILSCALE_CLI" ]] \
        || die "the local Tailscale CLI path is unavailable"
    [[ -x "$HOST_INSTALLER" && -x "$BOOTSTRAP_SCRIPT" ]] \
        || die "worker lifecycle scripts must be executable"
    [[ -f "$SESSION_HELPER_SOURCE" && ! -L "$SESSION_HELPER_SOURCE" ]] \
        || die "worker session helper source is missing or unsafe"
    [[ -f "$CHAT_SOURCE" && ! -L "$CHAT_SOURCE" ]] \
        || die "structured chat broker source is missing or unsafe"
    [[ -f "$MCP_SOURCE" && ! -L "$MCP_SOURCE" ]] \
        || die "worker MCP source is missing or unsafe"
    [[ -f "$CLAUDE_SESSIONS_SOURCE" && ! -L "$CLAUDE_SESSIONS_SOURCE" ]] \
        || die "Claude session adapter source is missing or unsafe"
    [[ -f "$CLAUDE_REQUIREMENTS_SOURCE" && ! -L "$CLAUDE_REQUIREMENTS_SOURCE" ]] \
        || die "Claude SDK requirements source is missing or unsafe"
    [[ -f "$NODE_EXPORTER_TEMPLATE" && ! -L "$NODE_EXPORTER_TEMPLATE" ]] \
        || die "missing or unsafe node-exporter template"
    for command in \
        "$SECURITY_METRICS_COLLECTOR" \
        "$SECURITY_METRICS_SERVICE" \
        "$SECURITY_METRICS_TIMER"; do
        [[ -f "$command" && ! -L "$command" ]] \
            || die "missing or unsafe security-metrics lifecycle file"
    done
    [[ -x "$SECURITY_METRICS_COLLECTOR" ]] \
        || die "security-metrics collector must be executable"
    [[ -f "$OPERATOR_PRIVATE_KEY" && -r "$OPERATOR_PRIVATE_KEY" ]] \
        || die "operator private key is unavailable: $OPERATOR_PRIVATE_KEY"
    [[ -f "$OPERATOR_PUBLIC_KEY" && -r "$OPERATOR_PUBLIC_KEY" ]] \
        || die "operator public key is unavailable: $OPERATOR_PUBLIC_KEY"
    fingerprint="$(/usr/bin/ssh-keygen -lf "$OPERATOR_PUBLIC_KEY" -E sha256 \
        | /usr/bin/awk 'NR == 1 { print $2 }')"
    [[ "$fingerprint" == "$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT" ]] \
        || die "local operator key does not match the worker baseline"
}

validate_number() {
    local number="$1"

    [[ "$number" =~ ^[1-9][0-9]{0,5}$ ]] || die "worker number must be from 1 to 999999"
}

worker_name_for_number() {
    printf 'terminal-relay-worker-%s\n' "$1"
}

root_alias_for_number() {
    printf 'terminal-relay-worker-%s-root\n' "$1"
}

keychain_password() {
    local account="$1"

    /usr/bin/security find-generic-password \
        -s "$TAILSCALE_KEYCHAIN_SERVICE" \
        -a "$account" \
        -w 2>/dev/null
}

have_tailscale_oauth() {
    keychain_password "$TAILSCALE_CLIENT_ID_ACCOUNT" >/dev/null \
        && keychain_password "$TAILSCALE_CLIENT_SECRET_ACCOUNT" >/dev/null
}

store_keychain_password() {
    local account="$1"
    local value="$2"

    printf '%s\n' "$value" | /usr/bin/security add-generic-password \
        -U \
        -s "$TAILSCALE_KEYCHAIN_SERVICE" \
        -a "$account" \
        -l "Terminal Relay Tailscale OAuth $account" \
        -w >/dev/null
}

hcloud_context_exists() {
    /opt/homebrew/bin/hcloud --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        firewall describe "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" \
        -o json >/dev/null 2>&1
}

verify_hcloud_project() {
    local firewall_json

    firewall_json="$(/opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        firewall describe "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" \
        -o json 2>/dev/null)" \
        || die "hcloud context '$TERMINAL_RELAY_HCLOUD_CONTEXT' cannot access the Terminal Relay project"
    [[ "$(printf '%s' "$firewall_json" | /usr/bin/jq -r '.id')" \
        == "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" ]] \
        || die "hcloud context resolved the wrong firewall ID"
    [[ "$(printf '%s' "$firewall_json" | /usr/bin/jq -r '.name')" \
        == "$TERMINAL_RELAY_PROVIDER_FIREWALL_NAME" ]] \
        || die "hcloud context resolved the wrong project firewall"
}

configure_credentials() {
    local client_id
    local client_secret

    if ! hcloud_context_exists; then
        log "Creating the project-scoped hcloud context '$TERMINAL_RELAY_HCLOUD_CONTEXT'."
        /opt/homebrew/bin/hcloud context create "$TERMINAL_RELAY_HCLOUD_CONTEXT"
    fi
    verify_hcloud_project

    printf 'Tailscale OAuth client ID: ' >/dev/tty
    IFS= read -r client_id </dev/tty || die "OAuth client ID was not provided"
    printf 'Tailscale OAuth client secret: ' >/dev/tty
    IFS= read -r -s client_secret </dev/tty \
        || die "OAuth client secret was not provided"
    printf '\n' >/dev/tty
    [[ "$client_id" =~ ^[A-Za-z0-9_-]{8,}$ ]] || die "OAuth client ID format is invalid"
    [[ "$client_secret" =~ ^[A-Za-z0-9_-]{16,}$ ]] || die "OAuth client secret format is invalid"
    store_keychain_password "$TAILSCALE_CLIENT_ID_ACCOUNT" "$client_id"
    store_keychain_password "$TAILSCALE_CLIENT_SECRET_ACCOUNT" "$client_secret"
    client_id=""
    client_secret=""
    have_tailscale_oauth || die "Tailscale OAuth credentials were not stored"
    log "Lifecycle credentials are configured."
}

urlencode_stdin() {
    /usr/bin/python3 -c \
        'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().rstrip("\n"), safe=""))'
}

tailscale_access_token() {
    local client_id
    local client_secret
    local encoded_id
    local encoded_secret
    local response="$temporary_directory/tailscale-token.json"
    local token

    client_id="$(keychain_password "$TAILSCALE_CLIENT_ID_ACCOUNT")" \
        || die "Tailscale OAuth client ID is absent; run ./Scripts/manage-worker.sh configure"
    client_secret="$(keychain_password "$TAILSCALE_CLIENT_SECRET_ACCOUNT")" \
        || die "Tailscale OAuth client secret is absent; run ./Scripts/manage-worker.sh configure"
    encoded_id="$(printf '%s' "$client_id" | urlencode_stdin)"
    encoded_secret="$(printf '%s' "$client_secret" | urlencode_stdin)"
    client_id=""
    client_secret=""
    (
        umask 077
        printf 'client_id=%s&client_secret=%s&grant_type=client_credentials' \
            "$encoded_id" "$encoded_secret" \
            | /usr/bin/curl --proto '=https' --tlsv1.2 -fsS \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                --data-binary @- \
                -o "$response" \
                "$TAILSCALE_TOKEN_URL"
    )
    encoded_id=""
    encoded_secret=""
    token="$(/usr/bin/jq -er '.access_token' "$response")" \
        || die "Tailscale OAuth token response was invalid"
    [[ "$token" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || die "Tailscale OAuth access token format was invalid"
    printf '%s\n' "$token"
}

tailscale_curl_config() {
    local token="$1"
    local config="$temporary_directory/tailscale-curl.conf"

    (
        umask 077
        printf 'header = "Authorization: Bearer %s"\n' "$token" > "$config"
    )
    printf '%s\n' "$config"
}

create_tailscale_auth_key() {
    local token
    local curl_config
    local request="$temporary_directory/tailscale-key-request.json"
    local response="$temporary_directory/tailscale-key-response.json"
    local key_file="$temporary_directory/tailscale-auth-key"

    token="$(tailscale_access_token)"
    curl_config="$(tailscale_curl_config "$token")"
    token=""
    /usr/bin/jq -n \
        --arg tag "$TERMINAL_RELAY_TAILSCALE_TAG" \
        '{
            capabilities: {
                devices: {
                    create: {
                        reusable: false,
                        ephemeral: false,
                        preauthorized: true,
                        tags: [$tag]
                    }
                }
            },
            expirySeconds: 900
        }' > "$request"
    /bin/chmod 0600 "$request"
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsS \
        --config "$curl_config" \
        -H 'Content-Type: application/json' \
        -X POST \
        --data-binary "@$request" \
        -o "$response" \
        "$TAILSCALE_API_ROOT/tailnet/-/keys"
    /usr/bin/jq -er '.key' "$response" > "$key_file" \
        || die "Tailscale auth-key response was invalid"
    /bin/chmod 0600 "$key_file"
    [[ "$(/usr/bin/wc -l < "$key_file" | /usr/bin/tr -d '[:space:]')" == 1 ]] \
        || die "Tailscale auth-key response contained unexpected data"
    printf '%s\n' "$key_file"
}

tailscale_ipv4_for_worker() {
    local worker_name="$1"

    "$TAILSCALE_CLI" status --json \
        | /usr/bin/jq -er --arg worker "$worker_name" '
            [
                .Peer[]
                | select(.HostName == $worker)
                | .TailscaleIPs[]
                | select(startswith("100."))
            ]
            | if length == 1 then .[0] else empty end
        '
}

ensure_provider_ssh_key() {
    local public_key
    local keys_json
    local key_id
    local created_json

    public_key="$(/usr/bin/awk 'NR == 1 { print $1 " " $2 }' "$OPERATOR_PUBLIC_KEY")"
    keys_json="$(/opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" ssh-key list -o json)"
    key_id="$(printf '%s' "$keys_json" | /usr/bin/jq -r --arg key "$public_key" '
        [
            .[]
            | select((.public_key | split(" ")[0:2] | join(" ")) == $key)
            | .id
        ]
        | if length == 1 then .[0] else empty end
    ')"
    if [[ -z "$key_id" ]]; then
        created_json="$(/opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            ssh-key create \
            --name terminal-relay-operator \
            --public-key-from-file "$OPERATOR_PUBLIC_KEY" \
            --label managed-by=terminal-relay \
            -o json)"
        key_id="$(printf '%s' "$created_json" | /usr/bin/jq -er '.id')"
        log "Created the shared operator public key in the Terminal Relay project."
    fi
    [[ "$key_id" =~ ^[0-9]+$ ]] || die "provider SSH key ID is invalid"
    printf '%s\n' "$key_id"
}

current_public_ipv4() {
    local address

    address="$(/usr/bin/curl --proto '=https' --tlsv1.2 -4fsS https://api.ipify.org)"
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "could not resolve the Mac's public IPv4 address"
    printf '%s\n' "$address"
}

firewall_is_attached() {
    local server_name="$1"
    local firewall_id="$2"

    /opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        server describe "$server_name" -o json \
        | /usr/bin/jq -e --argjson id "$firewall_id" \
            '(.public_net.firewalls // []) | any(.id == $id)' >/dev/null
}

ensure_bootstrap_firewall() {
    local worker_name="$1"
    local source_ipv4="$2"
    local firewall_name="$worker_name-bootstrap"
    local rules_file="$temporary_directory/bootstrap-firewall.json"
    local firewall_json
    local firewall_id

    /usr/bin/jq -n --arg source "$source_ipv4/32" '[
        {
            direction: "in",
            protocol: "icmp",
            source_ips: ["0.0.0.0/0", "::/0"]
        },
        {
            direction: "in",
            protocol: "udp",
            port: "41641",
            source_ips: ["0.0.0.0/0", "::/0"]
        },
        {
            direction: "in",
            protocol: "tcp",
            port: "22",
            source_ips: [$source]
        }
    ]' > "$rules_file"
    if firewall_json="$(/opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        firewall describe "$firewall_name" -o json 2>/dev/null)"; then
        firewall_id="$(printf '%s' "$firewall_json" | /usr/bin/jq -er '.id')"
        /opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            firewall replace-rules "$firewall_id" \
            --rules-file "$rules_file" >&2
        log "Updated temporary SSH firewall for $source_ipv4/32."
    else
        firewall_json="$(/opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            firewall create \
            --name "$firewall_name" \
            --label managed-by=terminal-relay \
            --label purpose=bootstrap \
            --rules-file "$rules_file" \
            -o json)"
        firewall_id="$(printf '%s' "$firewall_json" | /usr/bin/jq -er '.id')"
        log "Created temporary SSH firewall restricted to $source_ipv4/32."
    fi
    [[ "$firewall_id" =~ ^[0-9]+$ ]] || die "bootstrap firewall ID is invalid"
    printf '%s\n' "$firewall_id"
}

server_json() {
    /opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        server describe "$1" -o json 2>/dev/null
}

validate_existing_server() {
    local json="$1"
    local expected_name="$2"
    local expected_number="$3"

    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.name')" == "$expected_name" ]] \
        || die "provider server name mismatch"
    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.server_type.name')" \
        == "$TERMINAL_RELAY_SERVER_TYPE" ]] \
        || die "existing $expected_name has the wrong server type"
    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.datacenter.location.name')" \
        == "$TERMINAL_RELAY_SERVER_LOCATION" ]] \
        || die "existing $expected_name is in the wrong location"
    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.labels[\"managed-by\"] // empty')" \
        == terminal-relay ]] \
        || die "existing $expected_name is not lifecycle-managed"
    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.labels[\"worker-number\"] // empty')" \
        == "$expected_number" ]] \
        || die "existing $expected_name has the wrong worker-number label"
}

ensure_server() {
    local number="$1"
    local worker_name="$2"
    local ssh_key_id="$3"
    local bootstrap_firewall_id="$4"
    local existing
    local created

    if existing="$(server_json "$worker_name")"; then
        validate_existing_server "$existing" "$worker_name" "$number"
        printf '%s\n' "$existing"
        return
    fi
    created="$(/opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        server create \
        --name "$worker_name" \
        --type "$TERMINAL_RELAY_SERVER_TYPE" \
        --image "$TERMINAL_RELAY_SERVER_IMAGE" \
        --location "$TERMINAL_RELAY_SERVER_LOCATION" \
        --firewall "$bootstrap_firewall_id" \
        --ssh-key "$ssh_key_id" \
        --label managed-by=terminal-relay \
        --label baseline="$TERMINAL_RELAY_BASELINE_VERSION" \
        --label worker-number="$number" \
        --start-after-create=true \
        -o json)"
    log "Created $worker_name."
    printf '%s\n' "$created" | /usr/bin/jq -c '.server // .'
}

attach_firewall() {
    local firewall_id="$1"
    local server_name="$2"

    if ! firewall_is_attached "$server_name" "$firewall_id"; then
        /opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            firewall apply-to-resource "$firewall_id" \
            --type server \
            --server "$server_name"
    fi
}

remove_firewall() {
    local firewall_id="$1"
    local server_name="$2"

    if firewall_is_attached "$server_name" "$firewall_id"; then
        /opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            firewall remove-from-resource "$firewall_id" \
            --type server \
            --server "$server_name"
    fi
}

wait_for_public_ssh() {
    local address="$1"
    local _attempt

    log "Waiting for Ubuntu SSH on $address."
    for _attempt in {1..60}; do
        if /usr/bin/ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o "UserKnownHostsFile=$temporary_directory/bootstrap-known-hosts" \
            -o IdentitiesOnly=yes \
            -i "$OPERATOR_PRIVATE_KEY" \
            "root@$address" true >/dev/null 2>&1; then
            return
        fi
        /bin/sleep 5
    done
    die "server did not become reachable through its restricted bootstrap firewall"
}

# The remote directory is client-expanded only after an exact safe-path check.
# shellcheck disable=SC2029
host_bundle() {
    local action="$1"
    local worker_name="$2"
    local target="$3"
    local auth_key_file="${4:-}"
    shift 4
    local -a ssh_options=("$@")
    local payload_directory="$temporary_directory/host-payload"
    local result="$temporary_directory/host-$action-result"
    local remote_directory
    local install_status

    /bin/rm -rf -- "$payload_directory"
    /bin/mkdir -m 0700 "$payload_directory"
    /bin/cp "$BASELINE_FILE" "$payload_directory/worker-baseline.env"
    /bin/cp \
        "$HOST_INSTALLER" \
        "$NODE_EXPORTER_TEMPLATE" \
        "$SECURITY_METRICS_COLLECTOR" \
        "$SECURITY_METRICS_SERVICE" \
        "$SECURITY_METRICS_TIMER" \
        "$payload_directory/"
    /bin/chmod 0700 "$payload_directory/install-worker-host.sh"
    if [[ -n "$auth_key_file" ]]; then
        /bin/cp "$auth_key_file" "$payload_directory/tailscale-auth-key"
        /bin/chmod 0600 "$payload_directory/tailscale-auth-key"
    fi

    remote_directory="$(/usr/bin/ssh "${ssh_options[@]}" "$target" \
        '/usr/bin/mktemp -d /tmp/terminal-relay-host-install.XXXXXX')" \
        || die "could not create a remote installer directory"
    [[ "$remote_directory" =~ ^/tmp/terminal-relay-host-install\.[A-Za-z0-9]+$ ]] \
        || die "remote installer returned an unsafe temporary path"
    if ! /usr/bin/tar --no-xattrs -C "$payload_directory" -cf - . \
        | /usr/bin/ssh "${ssh_options[@]}" "$target" \
            "/usr/bin/tar --no-same-owner --no-same-permissions -xf - -C '$remote_directory'"; then
        /usr/bin/ssh "${ssh_options[@]}" "$target" \
            "/bin/rm -rf -- '$remote_directory'" >/dev/null 2>&1 || true
        die "could not transfer the host installer bundle"
    fi

    set +e
    /usr/bin/ssh "${ssh_options[@]}" "$target" \
        "/bin/chown -R root:root '$remote_directory' \
        && /bin/chmod 0700 '$remote_directory/install-worker-host.sh' \
        && if [ '$action' = enroll ]; then \
            /bin/chmod 0600 '$remote_directory/tailscale-auth-key'; \
            /bin/bash '$remote_directory/install-worker-host.sh' \
                enroll '$worker_name' '$remote_directory/tailscale-auth-key'; \
        else \
            /bin/bash '$remote_directory/install-worker-host.sh' '$action' '$worker_name'; \
        fi" | /usr/bin/tee "$result"
    install_status="${PIPESTATUS[0]}"
    set -e
    /usr/bin/ssh "${ssh_options[@]}" "$target" \
        "/bin/rm -rf -- '$remote_directory'" >/dev/null 2>&1 || true
    [[ "$install_status" -eq 0 ]] || die "remote host $action failed"
    HOST_BUNDLE_RESULT="$result"
}

parse_enrollment_ipv4() {
    local result="$1"
    local address

    [[ "$(/usr/bin/grep -c '^TERMINAL_RELAY_TAILSCALE_V1$' "$result")" -eq 1 ]] \
        || die "remote Tailscale enrollment did not return a valid result"
    [[ "$(/usr/bin/grep -c '^TERMINAL_RELAY_TAILSCALE_END$' "$result")" -eq 1 ]] \
        || die "remote Tailscale enrollment result was incomplete"
    address="$(/usr/bin/awk -F= '$1 == "ipv4" { count++; value=$2 } END {
        if (count == 1) print value
    }' "$result")"
    [[ "$address" =~ ^100\. ]] || die "remote Tailscale IPv4 result was invalid"
    printf '%s\n' "$address"
}

parse_host_ipv4() {
    local result="$1"
    local address

    [[ "$(/usr/bin/grep -c '^TERMINAL_RELAY_HOST_RESULT_V1$' "$result")" -eq 1 ]] \
        || die "remote host reconciliation did not return a valid result"
    [[ "$(/usr/bin/grep -c '^TERMINAL_RELAY_HOST_RESULT_END$' "$result")" -eq 1 ]] \
        || die "remote host reconciliation result was incomplete"
    address="$(/usr/bin/awk -F= '$1 == "tailscale_ipv4" { count++; value=$2 } END {
        if (count == 1) print value
    }' "$result")"
    [[ "$address" =~ ^100\. ]] || die "remote host Tailscale IPv4 result was invalid"
    printf '%s\n' "$address"
}

update_ssh_aliases() {
    local number="$1"
    local address="$2"
    local worker_name
    local root_alias
    local stripped="$temporary_directory/ssh-config-stripped"
    local updated="$temporary_directory/ssh-config-updated"
    local backup
    local inserted=false
    local line

    worker_name="$(worker_name_for_number "$number")"
    root_alias="$(root_alias_for_number "$number")"
    /usr/bin/install -d -m 0700 "$HOME/.ssh"
    [[ ! -e "$SSH_CONFIG" || -f "$SSH_CONFIG" && ! -L "$SSH_CONFIG" ]] \
        || die "SSH config is not a safe regular file"
    if [[ -f "$SSH_CONFIG" ]]; then
        /usr/bin/awk -v runtime="$worker_name" -v root="$root_alias" '
            /^Host[[:space:]]+/ {
                skip = ($0 == "Host " runtime || $0 == "Host " root)
            }
            !skip { print }
        ' "$SSH_CONFIG" > "$stripped"
    else
        : > "$stripped"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$inserted" == false && "$line" == "Host *" ]]; then
            {
                printf 'Host %s\n' "$worker_name"
                printf '    # Managed private route for Terminal Relay Worker %s.\n' "$number"
                printf '    HostName %s\n' "$address"
                printf '    User terminal-relay\n'
                printf '    IdentityFile ~/.ssh/hetzner_key\n'
                printf '    IdentitiesOnly yes\n\n'
                printf 'Host %s\n' "$root_alias"
                printf '    # Managed private repair route for Terminal Relay Worker %s.\n' "$number"
                printf '    HostName %s\n' "$address"
                printf '    User root\n'
                printf '    IdentityFile ~/.ssh/hetzner_key\n'
                printf '    IdentitiesOnly yes\n\n'
            } >> "$updated"
            inserted=true
        fi
        printf '%s\n' "$line" >> "$updated"
    done < "$stripped"
    if [[ "$inserted" == false ]]; then
        {
            printf '\nHost %s\n' "$worker_name"
            printf '    HostName %s\n' "$address"
            printf '    User terminal-relay\n'
            printf '    IdentityFile ~/.ssh/hetzner_key\n'
            printf '    IdentitiesOnly yes\n\n'
            printf 'Host %s\n' "$root_alias"
            printf '    HostName %s\n' "$address"
            printf '    User root\n'
            printf '    IdentityFile ~/.ssh/hetzner_key\n'
            printf '    IdentitiesOnly yes\n'
        } >> "$updated"
    fi
    if [[ -f "$SSH_CONFIG" ]] && /usr/bin/cmp -s "$updated" "$SSH_CONFIG"; then
        return
    fi
    if [[ -f "$SSH_CONFIG" ]]; then
        backup="$SSH_CONFIG.backup.$(/bin/date -u +%Y%m%dT%H%M%SZ)"
        /bin/cp -p "$SSH_CONFIG" "$backup"
        log "Backed up SSH config to $backup."
    fi
    /bin/chmod 0600 "$updated"
    /bin/mv -f "$updated" "$SSH_CONFIG"
    log "Installed private SSH aliases for Worker $number."
}

resolve_private_ipv4() {
    local number="$1"
    local alias
    local config
    local address

    alias="$(root_alias_for_number "$number")"
    config="$(/usr/bin/ssh -G "$alias" 2>/dev/null)" \
        || die "could not resolve SSH alias $alias"
    address="$(printf '%s\n' "$config" | /usr/bin/awk '$1 == "hostname" { print $2; exit }')"
    [[ "$address" =~ ^100\. ]] || die "$alias does not resolve to a Tailscale IPv4 address"
    printf '%s\n' "$address"
}

accept_private_host_key() {
    local number="$1"
    local root_alias

    root_alias="$(root_alias_for_number "$number")"
    /usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "$root_alias" true >/dev/null \
        || die "private root SSH failed for $root_alias"
}

run_private_host_action() {
    local action="$1"
    local number="$2"
    local worker_name
    local root_alias

    worker_name="$(worker_name_for_number "$number")"
    root_alias="$(root_alias_for_number "$number")"
    host_bundle "$action" "$worker_name" "$root_alias" "" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=yes
}

bootstrap_application() {
    local number="$1"
    local worker_name

    worker_name="$(worker_name_for_number "$number")"
    log "Applying the managed application runtime to Worker $number."
    "$BOOTSTRAP_SCRIPT" \
        --identity "$OPERATOR_PRIVATE_KEY" \
        --worker-number "$number" \
        --yes \
        "root@$worker_name"
}

verify_application() {
    local number="$1"
    local alias
    local expected_helper_digest
    local expected_chat_digest
    local expected_mcp_digest
    local expected_claude_sessions_digest
    local expected_claude_requirements_digest
    local expected_claude_sdk_version
    local expected_runtime_updater_digest
    local expected_runtime_public_key_digest
    local expected_runtime_version
    local output

    alias="$(worker_name_for_number "$number")"
    expected_helper_digest="$(/usr/bin/shasum -a 256 "$SESSION_HELPER_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    [[ "$expected_helper_digest" =~ ^[a-f0-9]{64}$ ]] \
        || die "could not fingerprint the worker session helper source"
    expected_chat_digest="$(/usr/bin/shasum -a 256 "$CHAT_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    [[ "$expected_chat_digest" =~ ^[a-f0-9]{64}$ ]] \
        || die "could not fingerprint the structured chat broker source"
    expected_mcp_digest="$(/usr/bin/shasum -a 256 "$MCP_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    [[ "$expected_mcp_digest" =~ ^[a-f0-9]{64}$ ]] \
        || die "could not fingerprint the worker MCP source"
    expected_claude_sessions_digest="$(/usr/bin/shasum -a 256 "$CLAUDE_SESSIONS_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    [[ "$expected_claude_sessions_digest" =~ ^[a-f0-9]{64}$ ]] \
        || die "could not fingerprint the Claude session adapter source"
    expected_claude_requirements_digest="$(/usr/bin/shasum -a 256 "$CLAUDE_REQUIREMENTS_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    [[ "$expected_claude_requirements_digest" =~ ^[a-f0-9]{64}$ ]] \
        || die "could not fingerprint the Claude SDK requirements"
    expected_claude_sdk_version="$(/usr/bin/sed -n \
        's/^claude-agent-sdk==//p' "$CLAUDE_REQUIREMENTS_SOURCE")"
    [[ "$expected_claude_sdk_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "could not read the pinned Claude Agent SDK version"
    expected_runtime_updater_digest="$(/usr/bin/shasum -a 256 "$RUNTIME_UPDATER_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    expected_runtime_public_key_digest="$(/usr/bin/shasum -a 256 "$RUNTIME_PUBLIC_KEY_SOURCE" \
        | /usr/bin/awk '{ print $1; exit }')"
    expected_runtime_version="$("$STABLE_RUNTIME_PREFLIGHT")" \
        || die "current runtime payload has not reached the signed stable feed"
    output="$(/usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=yes \
        "$alias" \
        "/bin/bash -s -- '$expected_helper_digest' '$expected_chat_digest' '$expected_mcp_digest' '$expected_claude_sessions_digest' '$expected_claude_requirements_digest' '$expected_claude_sdk_version' '$expected_runtime_updater_digest' '$expected_runtime_public_key_digest' '$expected_runtime_version'" <<'REMOTE'
set -euo pipefail
expected_helper_digest="$1"
expected_chat_digest="$2"
expected_mcp_digest="$3"
expected_claude_sessions_digest="$4"
expected_claude_requirements_digest="$5"
expected_claude_sdk_version="$6"
expected_runtime_updater_digest="$7"
expected_runtime_public_key_digest="$8"
expected_runtime_version="$9"
safe_path="/usr/local/bin:/usr/bin:/bin"
session_helper="/usr/local/bin/terminal-relay-session"
chat_broker="/usr/local/bin/terminal-relay-chat"
mcp_server="/usr/local/bin/terminal-relay-mcp"
claude_sessions="/usr/local/bin/terminal-relay-claude-sessions"
claude_sdk="/opt/terminal-relay/claude-session-sdk/current"
codex_restart_marker="/home/terminal-relay/.local/state/terminal-relay/codex-app-server-restart-required"
codex_app_server_session="terminal-relay-account-server"
provider_accounts_root="/home/terminal-relay/.local/share/terminal-relay/provider-accounts-v1"
provider_activation_marker="$provider_accounts_root/activated"
export PATH="$safe_path"

test "$(id -un)" = terminal-relay
test "$(id -gn)" = terminal-relay
test "$(stat -c '%U:%G:%a' /workspace)" = terminal-relay:terminal-relay:750
test "$(sha256sum "$session_helper" | awk '{ print $1; exit }')" = "$expected_helper_digest"
test "$(sha256sum "$chat_broker" | awk '{ print $1; exit }')" = "$expected_chat_digest"
test "$(sha256sum "$mcp_server" | awk '{ print $1; exit }')" = "$expected_mcp_digest"
test "$(sha256sum "$claude_sessions" | awk '{ print $1; exit }')" = "$expected_claude_sessions_digest"
test "$(sha256sum "$claude_sdk/requirements.txt" | awk '{ print $1; exit }')" = "$expected_claude_requirements_digest"
test "$(sha256sum /usr/local/sbin/terminal-relay-runtime-update | awk '{ print $1; exit }')" = "$expected_runtime_updater_digest"
test "$(sha256sum /etc/terminal-relay/runtime-update-public.pem | awk '{ print $1; exit }')" = "$expected_runtime_public_key_digest"
test "$(stat -c '%U:%G:%a' "$claude_sessions")" = root:root:755
test "$(stat -c '%U:%G:%a' "$chat_broker")" = root:root:755
test -x "$claude_sdk/bin/python3"
test "$("$claude_sdk/bin/python3" "$claude_sessions" version)" = "$expected_claude_sdk_version"
test "$(command -v bwrap)" = /usr/bin/bwrap
/usr/bin/bwrap \
    --unshare-user \
    --unshare-net \
    --ro-bind / / \
    /bin/true

account_routing_active=0
if [[ -e "$provider_activation_marker" || -L "$provider_activation_marker" ]]; then
    test -f "$provider_activation_marker"
    test ! -L "$provider_activation_marker"
    test "$(stat -c '%U:%G:%a' "$provider_activation_marker")" \
        = terminal-relay:terminal-relay:600
    test "$(< "$provider_activation_marker")" = 'version|1'
    account_routing_active=1
fi

if [[ "$account_routing_active" -eq 1 ]]; then
    "$session_helper" __schedule-all-codex-app-server-restarts
    test "$(stat -c '%U:%G:%a' "$codex_restart_marker")" \
        = terminal-relay:terminal-relay:600
    codex_profile_count=0
    shopt -s nullglob
    for profile in "$provider_accounts_root"/*/profile; do
        grep -Fxq 'provider|codex' "$profile" || continue
        account_id="$(basename "$(dirname "$profile")")"
        [[ "$account_id" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]
        account_restart_marker="/home/terminal-relay/.local/state/terminal-relay/codex-$account_id-app-server-restart-required"
        test -f "$account_restart_marker"
        test ! -L "$account_restart_marker"
        test "$(stat -c '%U:%G:%a' "$account_restart_marker")" \
            = terminal-relay:terminal-relay:600
        codex_profile_count=$((codex_profile_count + 1))
    done
    shopt -u nullglob
    [[ "$codex_profile_count" -ge 1 ]]
    "$session_helper" status-v2 >/dev/null
else
    restart_required=0
    if [[ -e "$codex_restart_marker" || -L "$codex_restart_marker" ]]; then
        restart_required=1
    fi
    if /usr/bin/tmux -f /dev/null -L terminal-relay \
        has-session -t "$codex_app_server_session" 2>/dev/null; then
        app_server_pid="$(/usr/bin/tmux -f /dev/null -L terminal-relay \
            display-message -p -t "$codex_app_server_session" '#{pane_pid}')"
        [[ "$app_server_pid" =~ ^[1-9][0-9]*$ ]]
        app_server_path="$(/usr/bin/tr '\0' '\n' < "/proc/$app_server_pid/environ" \
            | /usr/bin/sed -n 's/^PATH=//p')"
        if [[ "$app_server_path" != "$safe_path" ]]; then
            restart_required=1
        fi
    fi
    if [[ "$restart_required" -eq 1 ]]; then
        "$session_helper" __schedule-all-codex-app-server-restarts
    fi
    "$session_helper" __verify-codex-account >/dev/null
    if [[ -e "$codex_restart_marker" || -L "$codex_restart_marker" ]]; then
        test -f "$codex_restart_marker"
        test ! -L "$codex_restart_marker"
        test "$(stat -c '%U:%G:%a' "$codex_restart_marker")" \
            = terminal-relay:terminal-relay:600
        active_codex_terminals="$("$session_helper" status \
            | /usr/bin/awk -F'|' '$1 == "session" && $2 == "codex" { count++ } END { print count + 0 }')"
        [[ "$active_codex_terminals" =~ ^[1-9][0-9]*$ ]]
    else
        test ! -L "$codex_restart_marker"
    fi

    /usr/bin/tmux -f /dev/null -L terminal-relay \
        has-session -t "$codex_app_server_session" 2>/dev/null
    app_server_pid="$(/usr/bin/tmux -f /dev/null -L terminal-relay \
        display-message -p -t "$codex_app_server_session" '#{pane_pid}')"
    [[ "$app_server_pid" =~ ^[1-9][0-9]*$ ]]
    app_server_path="$(/usr/bin/tr '\0' '\n' < "/proc/$app_server_pid/environ" \
        | /usr/bin/sed -n 's/^PATH=//p')"
    test "$app_server_path" = "$safe_path"
fi

codex --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'
claude --version | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'
if [[ "$account_routing_active" -eq 0 ]]; then
    claude auth status --json 2>/dev/null \
        | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'
fi
systemctl is-enabled --quiet terminal-relay-session-restore@terminal-relay.service
systemctl is-active --quiet terminal-relay-session-restore@terminal-relay.service
systemctl is-enabled --quiet terminal-relay-agent-update.timer
systemctl is-active --quiet terminal-relay-agent-update.timer
systemctl is-enabled --quiet terminal-relay-runtime-update.timer
systemctl is-active --quiet terminal-relay-runtime-update.timer
systemctl is-enabled --quiet terminal-relay-runtime-update.path
systemctl is-active --quiet terminal-relay-runtime-update.path
if [[ "$account_routing_active" -eq 1 ]]; then
    "$session_helper" provider-accounts-v1 >/dev/null
    "$session_helper" status-v2 >/dev/null
else
    "$session_helper" status >/dev/null
    /usr/bin/python3 "$chat_broker" ready \
        --provider codex \
        --codex-socket /home/terminal-relay/.local/state/terminal-relay/codex.sock \
        >/dev/null
    "$claude_sdk/bin/python3" "$chat_broker" ready --provider claude >/dev/null
fi
"$session_helper" runtime-info \
    | grep -Eq "^runtime\\|$expected_runtime_version\\|1\\|2\\|agent-sessions,chat-v1,chat-v2,file-attachments-v1,provider-accounts-v1,runtime-updates-v1,threads-v1,threads-v2,threads-v3$"
"$session_helper" runtime-update-status >/dev/null
printf 'application=ready\n'
REMOTE
)"
    [[ "$output" == application=ready ]] \
        || die "Worker $number application verification failed"
}

reconcile_one() {
    local number="$1"
    local address

    validate_number "$number"
    address="$(resolve_private_ipv4 "$number")"
    update_ssh_aliases "$number" "$address"
    accept_private_host_key "$number"
    log "Reconciling Worker $number host controls."
    run_private_host_action reconcile "$number"
    bootstrap_application "$number"
    run_private_host_action reconcile "$number"
    verify_application "$number"
    log "Worker $number matches $TERMINAL_RELAY_BASELINE_VERSION."
}

adoption_preflight() {
    local target="$1"
    local worker_id

    worker_id="$(/usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=yes \
        -o IdentitiesOnly=yes \
        -i "$OPERATOR_PRIVATE_KEY" \
        "$target" \
        "/bin/bash -s -- '$TERMINAL_RELAY_TAILSCALE_TAG' '$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT'" <<'REMOTE'
set -euo pipefail
expected_tag="$1"
expected_fingerprint="$2"
test "$(id -u)" = 0
tailscale status --json \
    | python3 -c 'import json,sys; expected=sys.argv[1]; data=json.load(sys.stdin); raise SystemExit(0 if expected in data["Self"].get("Tags", []) else 1)' "$expected_tag"
ssh-keygen -lf /root/.ssh/authorized_keys -E sha256 \
    | awk '{ print $2 }' \
    | grep -Fqx "$expected_fingerprint"
test -f /etc/terminal-relay/worker-id
cat /etc/terminal-relay/worker-id
REMOTE
)" || die "existing worker failed the tagged private-route adoption preflight"
    [[ "$worker_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
        || die "existing worker returned an invalid stable UUID"
    printf '%s\n' "$worker_id"
}

assign_adopted_tailscale_name() {
    local worker_name="$1"
    local address="$2"
    local target="$3"
    local converged_address
    local _attempt

    if converged_address="$(tailscale_ipv4_for_worker "$worker_name" 2>/dev/null)" \
        && [[ "$converged_address" == "$address" ]] \
        && /usr/bin/ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=yes \
            -o IdentitiesOnly=yes \
            -i "$OPERATOR_PRIVATE_KEY" \
            "$target" true >/dev/null 2>&1; then
        return
    fi

    /usr/bin/ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=yes \
        -o IdentitiesOnly=yes \
        -i "$OPERATOR_PRIVATE_KEY" \
        "$target" \
        "/usr/bin/tailscale set --accept-risk=lose-ssh --ssh=true --hostname='$worker_name'" \
        >/dev/null 2>&1 || true

    for _attempt in {1..30}; do
        if converged_address="$(tailscale_ipv4_for_worker "$worker_name" 2>/dev/null)" \
            && [[ "$converged_address" == "$address" ]] \
            && /usr/bin/ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=yes \
                -o IdentitiesOnly=yes \
                -i "$OPERATOR_PRIVATE_KEY" \
                "$target" true >/dev/null 2>&1; then
            return
        fi
        /bin/sleep 2
    done
    die "renamed Tailscale identity did not become reachable at $address"
}

adopt_worker() {
    local number="$1"
    local target="$2"
    local assume_yes="$3"
    local address
    local existing_address
    local worker_id
    local worker_name
    local response

    validate_number "$number"
    [[ "$target" == root@100.* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] \
        || die "adoption target must be root@ followed by a Tailscale IPv4 address"
    address="${target#root@}"
    [[ "$address" =~ ^100\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] \
        || die "adoption target is not a valid Tailscale IPv4 address"
    worker_name="$(worker_name_for_number "$number")"
    if existing_address="$(tailscale_ipv4_for_worker "$worker_name" 2>/dev/null)"; then
        [[ "$existing_address" == "$address" ]] \
            || die "$worker_name already belongs to another Tailscale address"
    fi
    worker_id="$(adoption_preflight "$target")"

    if [[ "$assume_yes" != true ]]; then
        printf '\nAdopt UUID %s at %s as Terminal Relay Worker %s.\n' \
            "$worker_id" "$address" "$number" >/dev/tty
        printf 'This renames the host and closes host OpenSSH. Continue? [y/N] ' >/dev/tty
        IFS= read -r response </dev/tty || die "adoption confirmation was not provided"
        case "$response" in
            y|Y|yes|YES) ;;
            *) die "cancelled" ;;
        esac
    fi

    log "Assigning $worker_name to existing UUID $worker_id."
    assign_adopted_tailscale_name "$worker_name" "$address" "$target"
    host_bundle reconcile "$worker_name" "$target" "" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=yes \
        -o IdentitiesOnly=yes \
        -i "$OPERATOR_PRIVATE_KEY"
    address="$(parse_host_ipv4 "$HOST_BUNDLE_RESULT")"
    update_ssh_aliases "$number" "$address"
    accept_private_host_key "$number"
    reconcile_one "$number"
}

verify_one() {
    local number="$1"

    validate_number "$number"
    accept_private_host_key "$number"
    run_private_host_action verify "$number"
    verify_application "$number"
    log "Worker $number is ready and matches $TERMINAL_RELAY_BASELINE_VERSION."
}

configured_worker_numbers() {
    [[ -f "$SSH_CONFIG" ]] || return
    /usr/bin/awk '
        $1 == "Host" && $2 ~ /^terminal-relay-worker-[1-9][0-9]*$/ {
            sub(/^terminal-relay-worker-/, "", $2)
            print $2
        }
    ' "$SSH_CONFIG" | /usr/bin/sort -nu
}

run_for_target() {
    local command="$1"
    local target="$2"
    local number
    local -a numbers=()

    if [[ "$target" == all ]]; then
        while IFS= read -r number; do
            [[ -n "$number" ]] || continue
            numbers+=("$number")
        done < <(configured_worker_numbers)
        ((${#numbers[@]} > 0)) || die "no managed worker aliases are configured"
        for number in "${numbers[@]}"; do
            "$command" "$number"
        done
    else
        "$command" "$target"
    fi
}

confirm_provision() {
    local worker_name="$1"
    local assume_yes="$2"
    local response

    [[ "$assume_yes" == true ]] && return
    printf '\nThis will create or resume %s in Hetzner project %s.\n' \
        "$worker_name" "$TERMINAL_RELAY_PROVIDER_PROJECT_ID" >/dev/tty
    printf 'It creates a billable %s server in %s. Continue? [y/N] ' \
        "$TERMINAL_RELAY_SERVER_TYPE" "$TERMINAL_RELAY_SERVER_LOCATION" >/dev/tty
    IFS= read -r response </dev/tty || die "confirmation was not provided"
    case "$response" in
        y|Y|yes|YES) ;;
        *) die "cancelled" ;;
    esac
}

provision_worker() {
    local number="$1"
    local assume_yes="$2"
    local worker_name
    local source_ipv4
    local bootstrap_firewall_id
    local ssh_key_id
    local json
    local public_ipv4
    local auth_key_file
    local enrollment_result
    local tailscale_ipv4

    validate_number "$number"
    worker_name="$(worker_name_for_number "$number")"
    confirm_provision "$worker_name" "$assume_yes"
    verify_hcloud_project
    have_tailscale_oauth \
        || die "Tailscale OAuth is not configured; run ./Scripts/manage-worker.sh configure"

    source_ipv4="$(current_public_ipv4)"
    bootstrap_firewall_id="$(ensure_bootstrap_firewall "$worker_name" "$source_ipv4")"
    ssh_key_id="$(ensure_provider_ssh_key)"
    json="$(ensure_server "$number" "$worker_name" "$ssh_key_id" "$bootstrap_firewall_id")"
    public_ipv4="$(printf '%s' "$json" | /usr/bin/jq -er '.public_net.ipv4.ip')"
    attach_firewall "$bootstrap_firewall_id" "$worker_name"
    wait_for_public_ssh "$public_ipv4"

    if tailscale_ipv4="$(tailscale_ipv4_for_worker "$worker_name" 2>/dev/null)"; then
        log "$worker_name already has one Tailscale identity; resuming."
    else
        auth_key_file="$(create_tailscale_auth_key)"
        host_bundle enroll "$worker_name" "root@$public_ipv4" "$auth_key_file" \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=yes \
            -o "UserKnownHostsFile=$temporary_directory/bootstrap-known-hosts" \
            -o IdentitiesOnly=yes \
            -i "$OPERATOR_PRIVATE_KEY"
        enrollment_result="$HOST_BUNDLE_RESULT"
        tailscale_ipv4="$(parse_enrollment_ipv4 "$enrollment_result")"
    fi
    update_ssh_aliases "$number" "$tailscale_ipv4"
    accept_private_host_key "$number"

    attach_firewall "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" "$worker_name"
    remove_firewall "$bootstrap_firewall_id" "$worker_name"
    /opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        firewall delete "$bootstrap_firewall_id"
    log "Removed the temporary public SSH route; only the shared provider firewall remains."

    reconcile_one "$number"
    verify_one "$number"
    log "Provisioning complete: Terminal Relay Worker $number at $tailscale_ipv4."
}

workspace_is_retirable() {
    local alias="$1"

    /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15 "$alias" '/bin/bash -s' <<'REMOTE'
set -euo pipefail
status=$(/usr/local/bin/terminal-relay-session status)
if printf '%s\n' "$status" | grep -q '^session|'; then
    echo "active Terminal Relay sessions exist" >&2
    exit 1
fi
for repository in /workspace/*; do
    [[ -e "$repository" ]] || continue
    [[ -d "$repository/.git" ]] || {
        echo "non-Git workspace entry blocks retirement: $repository" >&2
        exit 1
    }
    git -C "$repository" diff --quiet
    git -C "$repository" diff --cached --quiet
    [[ -z "$(git -C "$repository" status --porcelain --untracked-files=normal)" ]] || {
        echo "dirty repository blocks retirement: $repository" >&2
        exit 1
    }
    upstream=$(git -C "$repository" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || {
        echo "repository without upstream blocks retirement: $repository" >&2
        exit 1
    }
    [[ "$(git -C "$repository" rev-list --count "$upstream"..HEAD)" == 0 ]] || {
        echo "unpushed commits block retirement: $repository" >&2
        exit 1
    }
done
REMOTE
}

delete_tailscale_device() {
    local worker_name="$1"
    local token
    local curl_config
    local response="$temporary_directory/tailscale-devices.json"
    local device_id

    token="$(tailscale_access_token)"
    curl_config="$(tailscale_curl_config "$token")"
    token=""
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsS \
        --config "$curl_config" \
        -o "$response" \
        "$TAILSCALE_API_ROOT/tailnet/-/devices?fields=all"
    device_id="$(/usr/bin/jq -r --arg worker "$worker_name" '
        [
            .devices[]
            | select(.hostname == $worker)
            | .id
        ]
        | if length == 1 then .[0] else empty end
    ' "$response")"
    [[ -n "$device_id" ]] || {
        log "No exact Tailscale device remained for $worker_name."
        return
    }
    [[ "$device_id" =~ ^[A-Za-z0-9]+$ ]] || die "Tailscale device ID was invalid"
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsS \
        --config "$curl_config" \
        -X DELETE \
        "$TAILSCALE_API_ROOT/device/$device_id" >/dev/null
}

retire_worker() {
    local number="$1"
    local worker_name
    local runtime_alias
    local json
    local response

    validate_number "$number"
    worker_name="$(worker_name_for_number "$number")"
    runtime_alias="$worker_name"
    verify_hcloud_project
    json="$(server_json "$worker_name")" || die "provider server does not exist: $worker_name"
    validate_existing_server "$json" "$worker_name" "$number"
    workspace_is_retirable "$runtime_alias" \
        || die "retirement safety checks failed; preserve or clean the reported worker state"

    printf '\nRetiring %s permanently deletes its VM, local agent history, and deploy keys.\n' \
        "$worker_name" >/dev/tty
    printf 'Type the exact provider name to continue: ' >/dev/tty
    IFS= read -r response </dev/tty || die "retirement confirmation was not provided"
    [[ "$response" == "$worker_name" ]] || die "retirement confirmation did not match"

    /opt/homebrew/bin/hcloud \
        --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
        server delete "$worker_name"
    delete_tailscale_device "$worker_name"
    log "$worker_name was deleted; its SSH aliases remain as an audit trace until manually removed."
}

main() {
    local command="${1:-}"
    local target
    local assume_yes=false

    if [[ "$command" == -h || "$command" == --help ]]; then
        usage
        return
    fi

    load_baseline
    validate_local_prerequisites
    make_temporary_directory
    case "$command" in
        configure)
            [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
            configure_credentials
            ;;
        provision)
            shift
            if [[ "${1:-}" == --yes ]]; then
                assume_yes=true
                shift
            fi
            [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
            provision_worker "$1" "$assume_yes"
            ;;
        adopt)
            shift
            if [[ "${1:-}" == --yes ]]; then
                assume_yes=true
                shift
            fi
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            adopt_worker "$1" "$2" "$assume_yes"
            ;;
        reconcile)
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            target="$2"
            run_for_target reconcile_one "$target"
            ;;
        verify)
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            target="$2"
            run_for_target verify_one "$target"
            ;;
        retire)
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            retire_worker "$2"
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
