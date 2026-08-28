#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
readonly script_directory
repository_root="$(cd "$script_directory/.." && pwd -P)"
readonly repository_root
readonly server_directory="$repository_root/Server"
readonly baseline_file="${TERMINAL_RELAY_BASELINE_FILE:-$server_directory/worker-baseline.local.env}"
readonly pairing_model="$repository_root/TerminalRelay/Models/MobilePairingPayload.swift"
readonly pairing_generator="$script_directory/generate-review-pairing.swift"
readonly stable_runtime_preflight="$script_directory/verify-published-worker-runtime.sh"
readonly keychain_service="com.mpieras.TerminalRelay.app-review-worker"
readonly keychain_account="pairing-code"

temporary_directory=""
temporary_root=""
server_address=""
review_hcloud_config=""
ssh_options=()

die() {
    printf 'manage-review-worker: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[manage-review-worker] %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  ./Scripts/manage-review-worker.sh provision [--yes]
  ./Scripts/manage-review-worker.sh repurpose <server-name> [--yes]
  ./Scripts/manage-review-worker.sh authenticate
  ./Scripts/manage-review-worker.sh invite [--days N] [--max-devices N]
  ./Scripts/manage-review-worker.sh copy-code
  ./Scripts/manage-review-worker.sh reset
  ./Scripts/manage-review-worker.sh revoke
  ./Scripts/manage-review-worker.sh verify
  ./Scripts/manage-review-worker.sh retire [--yes]

The review worker is a dedicated public-SSH VM with no Tailscale route and only
synthetic repositories. Its reusable pairing code is stored in macOS Keychain
and copied to the clipboard; it is never printed or written to the repository.
EOF
}

cleanup() {
    local exit_code=$?
    local parent
    local name

    trap - EXIT
    if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
        parent="$(dirname "$temporary_directory")"
        name="$(basename "$temporary_directory")"
        if [[ "$parent" == "$temporary_root" \
            && "$name" == terminal-relay-review-worker.* ]]; then
            /bin/rm -rf -- "$temporary_directory"
        else
            printf 'manage-review-worker: refusing to clean unexpected temporary path\n' >&2
            exit_code=1
        fi
    fi
    exit "$exit_code"
}
trap cleanup EXIT

make_temporary_directory() {
    temporary_root="${TMPDIR:-/tmp}"
    [[ "$temporary_root" == /* && -d "$temporary_root" ]] \
        || die "the temporary directory root is invalid"
    temporary_root="$(cd "$temporary_root" && pwd -P)"
    temporary_directory="$(/usr/bin/mktemp -d \
        "$temporary_root/terminal-relay-review-worker.XXXXXX")"
    /bin/chmod 0700 "$temporary_directory"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

load_configuration() {
    local variable

    [[ -f "$baseline_file" && ! -L "$baseline_file" ]] \
        || die "missing local worker baseline"
    # shellcheck disable=SC1090
    . "$baseline_file"
    for variable in \
        TERMINAL_RELAY_PROVIDER_FIREWALL_ID \
        TERMINAL_RELAY_PROVIDER_FIREWALL_NAME \
        TERMINAL_RELAY_HCLOUD_CONTEXT \
        TERMINAL_RELAY_SERVER_TYPE \
        TERMINAL_RELAY_SERVER_LOCATION \
        TERMINAL_RELAY_SERVER_IMAGE; do
        [[ -n "${!variable:-}" && "${!variable}" != REPLACE_ME ]] \
            || die "the local worker baseline is not fully configured"
    done

    review_server_name="${TERMINAL_RELAY_REVIEW_SERVER_NAME:-terminal-relay-app-review}"
    review_server_type="${TERMINAL_RELAY_REVIEW_SERVER_TYPE:-$TERMINAL_RELAY_SERVER_TYPE}"
    review_server_location="${TERMINAL_RELAY_REVIEW_SERVER_LOCATION:-$TERMINAL_RELAY_SERVER_LOCATION}"
    review_server_image="${TERMINAL_RELAY_REVIEW_SERVER_IMAGE:-$TERMINAL_RELAY_SERVER_IMAGE}"
    review_firewall_name="${TERMINAL_RELAY_REVIEW_FIREWALL_NAME:-terminal-relay-app-review-ingress}"
    operator_private_key="${TERMINAL_RELAY_OPERATOR_PRIVATE_KEY:-$HOME/.ssh/terminal-relay-operator}"
    operator_public_key="$operator_private_key.pub"
    review_hcloud_config="${TERMINAL_RELAY_REVIEW_HCLOUD_CONFIG:-}"

    [[ "$review_server_name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ \
        && "$review_firewall_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
        || die "the review worker names are invalid"
    [[ -f "$operator_private_key" && ! -L "$operator_private_key" \
        && -f "$operator_public_key" && ! -L "$operator_public_key" ]] \
        || die "the configured operator SSH identity is unavailable"
    if [[ -n "$review_hcloud_config" ]]; then
        [[ "$review_hcloud_config" == /* \
            && -f "$review_hcloud_config" \
            && ! -L "$review_hcloud_config" \
            && "$(/usr/bin/stat -f '%Lp' "$review_hcloud_config")" == 600 ]] \
            || die "the isolated hcloud config is unavailable or unsafe"
    fi
}

hcloud() {
    if [[ -n "$review_hcloud_config" ]]; then
        /opt/homebrew/bin/hcloud \
            --config "$review_hcloud_config" \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            "$@"
    else
        /opt/homebrew/bin/hcloud \
            --context "$TERMINAL_RELAY_HCLOUD_CONTEXT" \
            "$@"
    fi
}

verify_provider_project() {
    local firewall_json

    firewall_json="$(hcloud firewall describe \
        "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" -o json 2>/dev/null)" \
        || die "the configured hcloud context cannot access the expected project"
    [[ "$(printf '%s' "$firewall_json" | /usr/bin/jq -r '.id')" \
        == "$TERMINAL_RELAY_PROVIDER_FIREWALL_ID" \
        && "$(printf '%s' "$firewall_json" | /usr/bin/jq -r '.name')" \
        == "$TERMINAL_RELAY_PROVIDER_FIREWALL_NAME" ]] \
        || die "the configured hcloud context resolved the wrong project"
}

current_public_ipv4() {
    local address

    address="$(/usr/bin/curl --proto '=https' --tlsv1.2 -4fsS \
        https://api.ipify.org)"
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "the Mac public IPv4 address is unavailable"
    printf '%s\n' "$address"
}

write_firewall_rules() {
    local mode="$1"
    local rules_file="$2"
    local source_ipv4="${3:-}"

    if [[ "$mode" == bootstrap ]]; then
        [[ "$source_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
            || die "the bootstrap firewall source is invalid"
        /usr/bin/jq -n --arg source "$source_ipv4/32" '[
            {
                direction: "in",
                protocol: "icmp",
                source_ips: ["0.0.0.0/0", "::/0"]
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "22",
                source_ips: [$source]
            }
        ]' > "$rules_file"
    elif [[ "$mode" == review ]]; then
        /usr/bin/jq -n '[
            {
                direction: "in",
                protocol: "icmp",
                source_ips: ["0.0.0.0/0", "::/0"]
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "22",
                source_ips: ["0.0.0.0/0", "::/0"]
            }
        ]' > "$rules_file"
    else
        die "unknown firewall mode"
    fi
}

ensure_review_firewall() {
    local mode="$1"
    local source_ipv4="${2:-}"
    local rules_file="$temporary_directory/review-firewall.json"
    local firewall_json

    write_firewall_rules "$mode" "$rules_file" "$source_ipv4"
    if firewall_json="$(hcloud firewall describe "$review_firewall_name" \
        -o json 2>/dev/null)"; then
        review_firewall_id="$(printf '%s' "$firewall_json" \
            | /usr/bin/jq -er '(.firewall // .).id')"
        hcloud firewall replace-rules "$review_firewall_id" \
            --rules-file "$rules_file" >/dev/null
    else
        firewall_json="$(hcloud firewall create \
            --name "$review_firewall_name" \
            --label managed-by=terminal-relay \
            --label purpose=app-review \
            --rules-file "$rules_file" \
            -o json)"
        review_firewall_id="$(printf '%s' "$firewall_json" \
            | /usr/bin/jq -er '(.firewall // .).id')"
    fi
    [[ "$review_firewall_id" =~ ^[0-9]+$ ]] \
        || die "the review firewall identifier is invalid"
}

ensure_provider_ssh_key() {
    local public_key
    local keys_json
    local created_json

    public_key="$(/usr/bin/awk 'NR == 1 { print $1 " " $2 }' \
        "$operator_public_key")"
    keys_json="$(hcloud ssh-key list -o json)"
    provider_ssh_key_id="$(printf '%s' "$keys_json" | /usr/bin/jq -r \
        --arg key "$public_key" '
            [.[] | select((.public_key | split(" ")[0:2] | join(" ")) == $key) | .id]
            | if length == 1 then .[0] else empty end
        ')"
    if [[ -z "$provider_ssh_key_id" ]]; then
        created_json="$(hcloud ssh-key create \
            --name terminal-relay-operator \
            --public-key-from-file "$operator_public_key" \
            --label managed-by=terminal-relay \
            -o json)"
        provider_ssh_key_id="$(printf '%s' "$created_json" \
            | /usr/bin/jq -er '.id')"
    fi
    [[ "$provider_ssh_key_id" =~ ^[0-9]+$ ]] \
        || die "the provider SSH key identifier is invalid"
}

review_server_json() {
    hcloud server describe "$review_server_name" -o json 2>/dev/null
}

validate_server_json() {
    local json="$1"

    [[ "$(printf '%s' "$json" | /usr/bin/jq -r '.name')" \
        == "$review_server_name" \
        && "$(printf '%s' "$json" | /usr/bin/jq -r '.server_type.name')" \
        == "$review_server_type" \
        && "$(printf '%s' "$json" \
            | /usr/bin/jq -r '.datacenter.location.name // .location.name')" \
        == "$review_server_location" \
        && "$(printf '%s' "$json" \
            | /usr/bin/jq -r '.labels["managed-by"] // empty')" \
        == terminal-relay \
        && "$(printf '%s' "$json" \
            | /usr/bin/jq -r '.labels.purpose // empty')" \
        == app-review \
        && "$(printf '%s' "$json" \
            | /usr/bin/jq -r '(.private_net // []) | length')" \
        == 0 ]] \
        || die "an existing review server does not match the declared target"
}

ensure_review_server() {
    local json
    local created_json

    if json="$(review_server_json)"; then
        validate_server_json "$json"
    else
        created_json="$(hcloud server create \
            --name "$review_server_name" \
            --type "$review_server_type" \
            --image "$review_server_image" \
            --location "$review_server_location" \
            --firewall "$review_firewall_id" \
            --ssh-key "$provider_ssh_key_id" \
            --label managed-by=terminal-relay \
            --label purpose=app-review \
            --start-after-create=true \
            -o json)"
        json="$(printf '%s' "$created_json" | /usr/bin/jq -c '.server // .')"
        log "Created the isolated App Review server."
    fi
    validate_server_json "$json"
    server_address="$(printf '%s' "$json" | /usr/bin/jq -er '.public_net.ipv4.ip')"
    [[ "$server_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "the review server address is invalid"
    if printf '%s' "$json" | /usr/bin/jq -e \
        --argjson id "$review_firewall_id" '
            (.public_net.firewalls // [])
            | any(.id != $id)
        ' >/dev/null; then
        die "the App Review server has an unexpected additional firewall"
    fi
    if ! printf '%s' "$json" | /usr/bin/jq -e \
        --argjson id "$review_firewall_id" \
        '(.public_net.firewalls // []) | any(.id == $id)' >/dev/null; then
        hcloud firewall apply-to-resource "$review_firewall_id" \
            --type server \
            --server "$review_server_name" >/dev/null
    fi
}

prepare_ssh() {
    local known_hosts="$temporary_directory/known_hosts"
    local _attempt

    : > "$known_hosts"
    /bin/chmod 0600 "$known_hosts"
    for _attempt in {1..60}; do
        if /usr/bin/ssh-keyscan -T 3 -t ed25519 "$server_address" \
            > "$known_hosts" 2>/dev/null \
            && [[ -s "$known_hosts" ]]; then
            break
        fi
        /bin/sleep 2
    done
    [[ -s "$known_hosts" ]] || die "the review server did not expose an ED25519 host key"
    ssh_options=(
        -o BatchMode=yes
        -o ConnectTimeout=15
        -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=$known_hosts"
        -o IdentitiesOnly=yes
        -i "$operator_private_key"
    )
    for _attempt in {1..30}; do
        if /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" /bin/true \
            >/dev/null 2>&1; then
            return
        fi
        /bin/sleep 2
    done
    die "the review server did not become reachable with the operator key"
}

install_review_worker() {
    local payload="$temporary_directory/payload"
    local runtime_version="$1"
    local payload_name

    /bin/mkdir -p "$payload"
    /bin/cp "$baseline_file" "$payload/worker-baseline.env"
    /bin/cp \
        "$server_directory/install-worker.sh" \
        "$server_directory/worker-runtime-files.txt" \
        "$server_directory/terminal-relay-review-admin" \
        "$server_directory/terminal-relay-review-enroll" \
        "$server_directory/terminal-relay-review-gateway" \
        "$payload/"
    while IFS= read -r payload_name; do
        /bin/cp "$server_directory/$payload_name" "$payload/"
    done < <(/usr/bin/awk -F'|' '!/^#/ && NF { print $1 }' \
        "$server_directory/worker-runtime-files.txt")
    "$script_directory/write-installed-runtime-manifest.sh" \
        "$runtime_version" \
        "$payload/runtime-manifest.json"
    /bin/cp -R "$server_directory/worker-config" "$payload/worker-config"
    /bin/chmod 0600 "$payload/worker-baseline.env"

    /usr/bin/tar --no-xattrs -cf - -C "$payload" . \
        | /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" '
set -euo pipefail
temporary_directory="$(/usr/bin/mktemp -d /tmp/terminal-relay-review-install.XXXXXX)"
cleanup() {
    exit_code=$?
    trap - EXIT
    case "$temporary_directory" in
        /tmp/terminal-relay-review-install.*)
            /bin/rm -rf -- "$temporary_directory"
            ;;
        *)
            exit_code=1
            ;;
    esac
    exit "$exit_code"
}
trap cleanup EXIT
/usr/bin/tar --no-same-owner --no-same-permissions -xf - -C "$temporary_directory"
/bin/chown -R root:root "$temporary_directory"
/bin/bash "$temporary_directory/install-worker.sh"
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-review-admin" \
    /usr/local/bin/terminal-relay-review-admin
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-review-enroll" \
    /usr/local/bin/terminal-relay-review-enroll
/usr/bin/install -o root -g root -m 0755 \
    "$temporary_directory/terminal-relay-review-gateway" \
    /usr/local/bin/terminal-relay-review-gateway
/usr/local/bin/terminal-relay-review-admin configure
/usr/local/bin/terminal-relay-review-admin reset
/usr/local/bin/terminal-relay-review-admin verify
'
}

resolve_existing_server() {
    local json

    verify_provider_project
    json="$(review_server_json)" || die "the App Review server is not provisioned"
    validate_server_json "$json"
    server_address="$(printf '%s' "$json" | /usr/bin/jq -er '.public_net.ipv4.ip')"
    prepare_ssh
}

confirm_billable_action() {
    local assume_yes="$1"
    local response

    [[ "$assume_yes" == true ]] && return
    printf 'Create or reconcile the billable %s App Review server in %s? [y/N] ' \
        "$review_server_type" "$review_server_location" >/dev/tty
    IFS= read -r response </dev/tty || die "confirmation was not provided"
    case "$response" in
        y|Y|yes|YES) ;;
        *) die "cancelled" ;;
    esac
}

provision() {
    local assume_yes="$1"
    local source_ipv4
    local runtime_version

    runtime_version="$("$stable_runtime_preflight")" \
        || die "current runtime payload has not reached the signed stable feed"
    confirm_billable_action "$assume_yes"
    verify_provider_project
    source_ipv4="$(current_public_ipv4)"
    ensure_review_firewall bootstrap "$source_ipv4"
    ensure_provider_ssh_key
    ensure_review_server
    prepare_ssh
    install_review_worker "$runtime_version"
    ensure_review_firewall review
    log "Provisioned the isolated App Review worker with public key-only SSH."
    log "Authenticate dedicated reviewer accounts before creating the review invitation."
}

strip_private_worker_state() {
    /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" '
set -euo pipefail
/usr/bin/systemctl disable --now docker.socket docker.service node-exporter \
    >/dev/null 2>&1 || true
if command -v tailscale >/dev/null 2>&1; then
    tailscale logout >/dev/null 2>&1 || true
    apt-mark unhold tailscale >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -y purge tailscale >/dev/null 2>&1 \
        || true
    /bin/rm -rf /var/lib/tailscale
    command -v tailscale >/dev/null 2>&1 \
        && { echo "tailscale could not be removed" >&2; exit 1; }
fi
if command -v ufw >/dev/null 2>&1; then
    ufw --force disable >/dev/null 2>&1 || true
fi
/usr/bin/pkill -u terminal-relay || true
/bin/rm -rf \
    /home/terminal-relay/.codex \
    /home/terminal-relay/.claude \
    /home/terminal-relay/.claude.json \
    /home/terminal-relay/.cache \
    /home/terminal-relay/.local/share/terminal-relay
/usr/bin/find /workspace -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
'
}

repurpose_server() {
    local assume_yes="$1"
    local source_name="$2"
    local runtime_version
    local source_json
    local json
    local firewall_id
    local response

    [[ -n "$source_name" ]] \
        || die "repurpose requires the name of an existing server"
    [[ "$source_name" != "$review_server_name" ]] \
        || die "the source server is already named as the review worker"
    runtime_version="$("$stable_runtime_preflight")" \
        || die "current runtime payload has not reached the signed stable feed"
    verify_provider_project
    if source_json="$(hcloud server describe "$source_name" -o json \
        2>/dev/null)"; then
        if review_server_json >/dev/null 2>&1; then
            die "a review server already exists; retire it before repurposing"
        fi
        [[ "$(printf '%s' "$source_json" | /usr/bin/jq -r '.server_type.name')" \
            == "$review_server_type" ]] \
            || die "the source server type does not match the review baseline"
        [[ "$(printf '%s' "$source_json" \
            | /usr/bin/jq -r '.datacenter.location.name // .location.name')" \
            == "$review_server_location" ]] \
            || die "the source server location does not match the review baseline"
        [[ "$(printf '%s' "$source_json" \
            | /usr/bin/jq -r '(.private_net // []) | length')" == 0 ]] \
            || die "the source server is attached to a private network"

        if [[ "$assume_yes" != true ]]; then
            printf 'Type REPURPOSE %s to wipe this worker (workspace, agent accounts, Tailscale) and convert it into the synthetic review worker: ' \
                "$source_name" >/dev/tty
            IFS= read -r response </dev/tty || die "confirmation was not provided"
            [[ "$response" == "REPURPOSE $source_name" ]] || die "cancelled"
        fi

        ensure_review_firewall bootstrap "$(current_public_ipv4)"
        hcloud server update "$source_name" --name "$review_server_name" \
            >/dev/null
        hcloud server add-label --overwrite "$review_server_name" \
            managed-by=terminal-relay >/dev/null
        hcloud server add-label --overwrite "$review_server_name" \
            purpose=app-review >/dev/null
    elif review_server_json >/dev/null 2>&1; then
        log "Resuming an interrupted repurpose of the existing review server."
        ensure_review_firewall bootstrap "$(current_public_ipv4)"
    else
        die "the source server is unavailable in the review project"
    fi
    json="$(review_server_json)" \
        || die "the renamed review server is unavailable"
    while IFS= read -r firewall_id; do
        [[ -n "$firewall_id" && "$firewall_id" != "$review_firewall_id" ]] \
            || continue
        hcloud firewall remove-from-resource "$firewall_id" \
            --type server --server "$review_server_name" >/dev/null
    done < <(printf '%s' "$json" \
        | /usr/bin/jq -r '(.public_net.firewalls // [])[].id')
    if ! printf '%s' "$json" | /usr/bin/jq -e \
        --argjson id "$review_firewall_id" \
        '(.public_net.firewalls // []) | any(.id == $id)' >/dev/null; then
        hcloud firewall apply-to-resource "$review_firewall_id" \
            --type server --server "$review_server_name" >/dev/null
        json="$(review_server_json)"
    fi
    validate_server_json "$json"
    server_address="$(printf '%s' "$json" \
        | /usr/bin/jq -er '.public_net.ipv4.ip')"
    prepare_ssh
    strip_private_worker_state
    install_review_worker "$runtime_version"
    ensure_review_firewall review
    log "Repurposed $source_name as the isolated App Review worker."
    log "Authenticate dedicated reviewer accounts before creating the review invitation."
}

authenticate() {
    resolve_existing_server
    if ! /usr/bin/ssh "${ssh_options[@]}" "terminal-relay@$server_address" \
        '/usr/bin/codex login status >/dev/null 2>&1'; then
        log "Codex review-account authentication is required."
        /usr/bin/ssh -tt "${ssh_options[@]}" "terminal-relay@$server_address" \
            '/usr/bin/codex login --device-auth'
    fi
    if ! /usr/bin/ssh "${ssh_options[@]}" "terminal-relay@$server_address" \
        '/usr/bin/claude auth status --json 2>/dev/null | /bin/grep -Eq '\''"loggedIn"[[:space:]]*:[[:space:]]*true'\'''; then
        log "Claude review-account authentication is required."
        /usr/bin/ssh -tt "${ssh_options[@]}" "terminal-relay@$server_address" \
            '/usr/bin/claude auth login'
    fi
    verify_authentication
    log "Dedicated review-agent accounts are authenticated."
}

verify_authentication() {
    /usr/bin/ssh "${ssh_options[@]}" "terminal-relay@$server_address" \
        '/usr/bin/codex login status >/dev/null 2>&1' \
        || die "the App Review worker has no Codex account"
    /usr/bin/ssh "${ssh_options[@]}" "terminal-relay@$server_address" \
        '/usr/bin/claude auth status --json 2>/dev/null | /bin/grep -Eq '\''"loggedIn"[[:space:]]*:[[:space:]]*true'\''' \
        || die "the App Review worker has no Claude account"
}

create_invitation() {
    local days="$1"
    local maximum_devices="$2"
    local fingerprint
    local expires_at
    local generator="$temporary_directory/generate-review-pairing"
    local entry_file="$temporary_directory/authorized-entry"
    local code_file="$temporary_directory/pairing-code"
    local code

    [[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 && "$days" -le 60 ]] \
        || die "review invitation days must be between 1 and 60"
    [[ "$maximum_devices" =~ ^[0-9]+$ \
        && "$maximum_devices" -ge 1 \
        && "$maximum_devices" -le 20 ]] \
        || die "review invitation device count must be between 1 and 20"
    resolve_existing_server
    verify_authentication
    fingerprint="$(/usr/bin/ssh-keygen -lf "$temporary_directory/known_hosts" \
        -E sha256 | /usr/bin/awk 'NR == 1 { print $2 }')"
    [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] \
        || die "the review worker host-key fingerprint is invalid"
    expires_at=$(( $(/bin/date +%s) + days * 24 * 60 * 60 ))

    /usr/bin/xcrun swiftc \
        "$pairing_model" \
        "$pairing_generator" \
        -o "$generator"
    "$generator" \
        "App Review Worker" \
        "$server_address" \
        22 \
        terminal-relay \
        "$fingerprint" \
        "$expires_at" \
        "$maximum_devices" \
        "$entry_file" \
        "$code_file"
    /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" \
        '/usr/local/bin/terminal-relay-review-admin install-invitation' \
        < "$entry_file"
    code="$(< "$code_file")"
    [[ "$code" == terminal-relay://pair-device\?* ]] \
        || die "the generated review pairing code is invalid"
    /usr/bin/security add-generic-password \
        -U \
        -s "$keychain_service" \
        -a "$keychain_account" \
        -l "Terminal Relay App Review pairing code" \
        -w "$code" >/dev/null
    printf '%s' "$code" | /usr/bin/pbcopy
    code=""
    log "Created the reusable review invitation and copied it to the clipboard."
}

copy_code() {
    /usr/bin/security find-generic-password \
        -s "$keychain_service" \
        -a "$keychain_account" \
        -w 2>/dev/null \
        | /usr/bin/pbcopy \
        || die "no App Review pairing code is stored in Keychain"
    log "Copied the App Review pairing code to the clipboard."
}

reset_worker() {
    resolve_existing_server
    /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" \
        '/usr/local/bin/terminal-relay-review-admin reset'
    log "Reset synthetic repositories, sessions, and enrolled review devices."
}

revoke_invitation() {
    resolve_existing_server
    /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" \
        '/usr/local/bin/terminal-relay-review-admin revoke'
    /usr/bin/security delete-generic-password \
        -s "$keychain_service" \
        -a "$keychain_account" >/dev/null 2>&1 || true
    log "Revoked the App Review invitation and enrolled review devices."
}

verify_worker() {
    local json
    local firewall_json

    verify_provider_project
    json="$(review_server_json)" || die "the App Review server is not provisioned"
    validate_server_json "$json"
    server_address="$(printf '%s' "$json" | /usr/bin/jq -er '.public_net.ipv4.ip')"
    firewall_json="$(hcloud firewall describe "$review_firewall_name" -o json)" \
        || die "the App Review firewall is unavailable"
    printf '%s' "$firewall_json" | /usr/bin/jq -e '
        (.rules | length == 2)
        and (.rules | any(
            .direction == "in"
            and .protocol == "tcp"
            and .port == "22"
            and (.source_ips | index("0.0.0.0/0"))
            and (.source_ips | index("::/0"))
        ))
    ' >/dev/null || die "the App Review firewall does not expose only the declared SSH route"
    prepare_ssh
    /usr/bin/ssh "${ssh_options[@]}" "root@$server_address" \
        '/usr/local/bin/terminal-relay-review-admin verify'
    verify_authentication
    log "The isolated App Review worker passed verification."
}

retire_worker() {
    local assume_yes="$1"
    local json
    local response

    verify_provider_project
    json="$(review_server_json)" || die "the App Review server is not provisioned"
    validate_server_json "$json"
    if [[ "$assume_yes" != true ]]; then
        printf 'Type DELETE %s to permanently retire the synthetic review worker: ' \
            "$review_server_name" >/dev/tty
        IFS= read -r response </dev/tty || die "confirmation was not provided"
        [[ "$response" == "DELETE $review_server_name" ]] || die "cancelled"
    fi
    hcloud server delete "$review_server_name" >/dev/null
    if hcloud firewall describe "$review_firewall_name" >/dev/null 2>&1; then
        hcloud firewall delete "$review_firewall_name" >/dev/null
    fi
    /usr/bin/security delete-generic-password \
        -s "$keychain_service" \
        -a "$keychain_account" >/dev/null 2>&1 || true
    log "Retired the App Review worker and removed its local pairing code."
}

main() {
    local command="${1:-}"
    local assume_yes=false
    local days=30
    local maximum_devices=8
    local source_server=""

    case "$command" in
        -h|--help|"")
            usage
            return
            ;;
        provision|repurpose|authenticate|invite|copy-code|reset|revoke|verify|retire)
            shift
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac

    if [[ "$command" == repurpose && $# -ge 1 && "$1" != --* ]]; then
        source_server="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)
                assume_yes=true
                shift
                ;;
            --days)
                [[ $# -ge 2 ]] || die "--days requires a value"
                days="$2"
                shift 2
                ;;
            --max-devices)
                [[ $# -ge 2 ]] || die "--max-devices requires a value"
                maximum_devices="$2"
                shift 2
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    require_command /opt/homebrew/bin/hcloud
    require_command /usr/bin/jq
    require_command /usr/bin/ssh
    require_command /usr/bin/ssh-keygen
    [[ "$(/usr/bin/uname -s)" == Darwin ]] \
        || die "the review worker lifecycle must run on macOS"
    make_temporary_directory
    load_configuration

    case "$command" in
        provision) provision "$assume_yes" ;;
        repurpose) repurpose_server "$assume_yes" "$source_server" ;;
        authenticate) authenticate ;;
        invite) create_invitation "$days" "$maximum_devices" ;;
        copy-code) copy_code ;;
        reset) reset_worker ;;
        revoke) revoke_invitation ;;
        verify) verify_worker ;;
        retire) retire_worker "$assume_yes" ;;
    esac
}

main "$@"
