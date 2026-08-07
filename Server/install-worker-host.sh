#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
baseline_file="$script_directory/worker-baseline.env"
node_exporter_template="$script_directory/node-exporter.service.template"
security_metrics_collector="$script_directory/terminal-relay-security-metrics"
security_metrics_service="$script_directory/terminal-relay-security-metrics.service"
security_metrics_timer="$script_directory/terminal-relay-security-metrics.timer"

fail() {
    printf '[terminal-relay-host] ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[terminal-relay-host] %s\n' "$*"
}

usage() {
    cat <<'EOF'
Usage:
  install-worker-host.sh enroll terminal-relay-worker-N AUTH_KEY_FILE
  install-worker-host.sh reconcile terminal-relay-worker-N
  install-worker-host.sh verify terminal-relay-worker-N
EOF
}

[[ -f "$baseline_file" && ! -L "$baseline_file" ]] \
    || fail "Missing or unsafe baseline file: $baseline_file"
[[ -f "$node_exporter_template" && ! -L "$node_exporter_template" ]] \
    || fail "Missing or unsafe node-exporter template: $node_exporter_template"
for required_file in \
    "$security_metrics_collector" \
    "$security_metrics_service" \
    "$security_metrics_timer"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] \
        || fail "Missing or unsafe security-metrics file: $required_file"
done
[[ -x "$security_metrics_collector" ]] \
    || fail "Security-metrics collector is not executable: $security_metrics_collector"
# shellcheck disable=SC1090
. "$baseline_file"

readonly state_directory="/etc/terminal-relay-host"
readonly state_version_file="$state_directory/baseline-version"
readonly state_name_file="$state_directory/provider-name"
readonly tailscale_keyring="/usr/share/keyrings/tailscale-archive-keyring.gpg"
readonly tailscale_source="/etc/apt/sources.list.d/tailscale.list"
readonly tailscale_key_url="https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg"
readonly tailscale_repository="deb [signed-by=$tailscale_keyring] https://pkgs.tailscale.com/stable/ubuntu noble main"
readonly node_exporter_unit="/etc/systemd/system/node-exporter.service"
readonly security_metrics_collector_path="/usr/local/sbin/terminal-relay-security-metrics"
readonly security_metrics_service_unit="/etc/systemd/system/terminal-relay-security-metrics.service"
readonly security_metrics_timer_unit="/etc/systemd/system/terminal-relay-security-metrics.timer"
readonly security_metrics_file="/var/lib/prometheus/node-exporter/fleet-security.prom"
readonly runtime_user="terminal-relay"
readonly runtime_keys="/home/$runtime_user/.ssh/authorized_keys"
readonly root_keys="/root/.ssh/authorized_keys"
backup_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly backup_timestamp

worker_name=""
tailscale_ipv4=""
tailscale_ipv6=""

validate_platform() {
    local architecture

    [[ -r /etc/os-release ]] || fail "Unable to read /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
        || fail "Ubuntu 24.04 is required."
    architecture="$(/usr/bin/dpkg --print-architecture)"
    [[ "$architecture" == "amd64" ]] || fail "amd64 is required."
    [[ -d /run/systemd/system ]] || fail "systemd is required."
}

validate_worker_name() {
    [[ "$worker_name" =~ ^terminal-relay-worker-([1-9][0-9]{0,5})$ ]] \
        || fail "Worker name must be terminal-relay-worker-N."
}

next_backup_path() {
    local destination="$1"
    local candidate="$destination.backup.$backup_timestamp"
    local suffix=1

    while [[ -e "$candidate" || -L "$candidate" ]]; do
        candidate="$destination.backup.$backup_timestamp.$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$candidate"
}

install_content() {
    local content="$1"
    local destination="$2"
    local owner="$3"
    local group="$4"
    local mode="$5"
    local parent
    local staged
    local backup

    parent="$(dirname "$destination")"
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] \
            || fail "Managed parent is not a safe directory: $parent"
    else
        /usr/bin/install -d -o "$owner" -g "$group" -m 0755 "$parent"
    fi
    staged="$(/usr/bin/mktemp "$parent/.terminal-relay-host.XXXXXX")"
    printf '%s\n' "$content" > "$staged"
    /bin/chown "$owner:$group" "$staged"
    /bin/chmod "$mode" "$staged"

    if [[ -f "$destination" && ! -L "$destination" ]] \
        && /usr/bin/cmp -s "$staged" "$destination" \
        && [[ "$(/usr/bin/stat -c '%U:%G:%a' "$destination")" == "$owner:$group:${mode#0}" ]]; then
        /bin/rm -f -- "$staged"
        return
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] \
            || fail "Refusing to replace unsafe managed path: $destination"
        backup="$(next_backup_path "$destination")"
        /bin/cp -a -- "$destination" "$backup"
        log "Backed up $destination to $backup"
    fi
    /bin/mv -f -- "$staged" "$destination"
    log "Installed $destination"
}

install_binary_file() {
    local source="$1"
    local destination="$2"
    local owner="$3"
    local group="$4"
    local mode="$5"
    local parent
    local staged
    local backup

    parent="$(dirname "$destination")"
    if [[ -e "$parent" || -L "$parent" ]]; then
        [[ -d "$parent" && ! -L "$parent" ]] \
            || fail "Managed parent is not a safe directory: $parent"
    else
        /usr/bin/install -d -o "$owner" -g "$group" -m 0755 "$parent"
    fi
    staged="$(/usr/bin/mktemp "$parent/.terminal-relay-host.XXXXXX")"
    /usr/bin/install -o "$owner" -g "$group" -m "$mode" "$source" "$staged"
    if [[ -f "$destination" && ! -L "$destination" ]] \
        && /usr/bin/cmp -s "$staged" "$destination" \
        && [[ "$(/usr/bin/stat -c '%U:%G:%a' "$destination")" == "$owner:$group:${mode#0}" ]]; then
        /bin/rm -f -- "$staged"
        return
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" ]] \
            || fail "Refusing to replace unsafe managed path: $destination"
        backup="$(next_backup_path "$destination")"
        /bin/cp -a -- "$destination" "$backup"
        log "Backed up $destination to $backup"
    fi
    /bin/mv -f -- "$staged" "$destination"
    log "Installed $destination"
}

install_tailscale_repository() {
    local temporary_key
    local primary_fingerprint

    export DEBIAN_FRONTEND=noninteractive
    /usr/bin/apt-get update
    /usr/bin/apt-get install -y --no-install-recommends ca-certificates curl gnupg
    temporary_key="$(/usr/bin/mktemp /tmp/terminal-relay-tailscale-key.XXXXXX)"
    trap '/bin/rm -f -- "$temporary_key"' RETURN
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL -o "$temporary_key" "$tailscale_key_url"
    primary_fingerprint="$(/usr/bin/gpg --batch --show-keys --with-colons "$temporary_key" \
        | /usr/bin/awk -F: '$1 == "fpr" { print toupper($10); exit }')"
    [[ "$primary_fingerprint" == "2596A99EAAB33821893C0A79458CA832957F5868" ]] \
        || fail "Tailscale signing key fingerprint mismatch."
    install_binary_file "$temporary_key" "$tailscale_keyring" root root 0644
    install_content "$tailscale_repository" "$tailscale_source" root root 0644
    /bin/rm -f -- "$temporary_key"
    trap - RETURN
    /usr/bin/apt-get update
    /usr/bin/apt-get install -y --no-install-recommends \
        --allow-downgrades \
        --allow-change-held-packages \
        "tailscale=$TERMINAL_RELAY_TAILSCALE_VERSION"
    /usr/bin/apt-mark hold tailscale >/dev/null
    /usr/bin/systemctl enable --now tailscaled.service
}

read_tailscale_addresses() {
    tailscale_ipv4="$(/usr/bin/tailscale ip -4 | /usr/bin/awk 'NR == 1 { print; exit }')"
    tailscale_ipv6="$(/usr/bin/tailscale ip -6 | /usr/bin/awk 'NR == 1 { print; exit }')"
    [[ "$tailscale_ipv4" =~ ^100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
        || fail "Unable to resolve a Tailscale IPv4 address."
    [[ "$tailscale_ipv6" == fd7a:* ]] \
        || fail "Unable to resolve a Tailscale IPv6 address."
}

validate_tailscale_identity() {
    local identity
    local identity_hostname
    local identity_tags
    local _attempt

    for _attempt in {1..15}; do
        identity="$(/usr/bin/tailscale status --json | /usr/bin/python3 -c '
import json
import sys
self_node = json.load(sys.stdin)["Self"]
print(self_node.get("HostName", ""))
print(" ".join(sorted(self_node.get("Tags", []))))
')"
        identity_hostname="$(printf '%s\n' "$identity" | /usr/bin/sed -n '1p')"
        identity_tags="$(printf '%s\n' "$identity" | /usr/bin/sed -n '2p')"
        if [[ "$identity_hostname" == "$worker_name" ]] \
            && printf '%s\n' "$identity_tags" | /bin/grep -Eq \
                "(^|[[:space:]])${TERMINAL_RELAY_TAILSCALE_TAG//:/\\:}([[:space:]]|$)"; then
            read_tailscale_addresses
            return
        fi
        /bin/sleep 1
    done
    [[ "$identity_hostname" == "$worker_name" ]] \
        || fail "Tailscale hostname does not match $worker_name."
    printf '%s\n' "$identity_tags" | /bin/grep -Eq \
        "(^|[[:space:]])${TERMINAL_RELAY_TAILSCALE_TAG//:/\\:}([[:space:]]|$)" \
        || fail "Tailscale identity is missing $TERMINAL_RELAY_TAILSCALE_TAG."
    fail "Tailscale identity did not converge."
}

enroll_tailscale() {
    local auth_key_file="$1"

    [[ -f "$auth_key_file" && ! -L "$auth_key_file" ]] \
        || fail "Tailscale auth-key file is missing or unsafe."
    [[ "$(/usr/bin/stat -c '%a' "$auth_key_file")" == "600" ]] \
        || fail "Tailscale auth-key file must have mode 0600."
    [[ "$(/usr/bin/wc -l < "$auth_key_file" | /usr/bin/tr -d '[:space:]')" == "1" ]] \
        || fail "Tailscale auth-key file must contain exactly one line."

    install_tailscale_repository
    /usr/bin/tailscale up \
        --auth-key="file:$auth_key_file" \
        --ssh \
        --hostname="$worker_name" \
        --advertise-tags="$TERMINAL_RELAY_TAILSCALE_TAG"
    validate_tailscale_identity
    printf '%s\n' 'TERMINAL_RELAY_TAILSCALE_V1'
    printf 'ipv4=%s\n' "$tailscale_ipv4"
    printf 'ipv6=%s\n' "$tailscale_ipv6"
    printf '%s\n' 'TERMINAL_RELAY_TAILSCALE_END'
}

ensure_private_reconcile_route() {
    local server_address

    [[ -n "${SSH_CONNECTION:-}" ]] \
        || fail "Reconcile must run through an SSH connection."
    server_address="$(printf '%s\n' "$SSH_CONNECTION" | /usr/bin/awk '{ print $3 }')"
    [[ "$server_address" == "$tailscale_ipv4" || "$server_address" == "$tailscale_ipv6" ]] \
        || fail "Reconcile must run over this worker's Tailscale address."
}

install_host_packages() {
    export DEBIAN_FRONTEND=noninteractive
    /usr/bin/apt-get update
    /usr/bin/apt-get install -y --no-install-recommends \
        --allow-downgrades \
        --allow-change-held-packages \
        "containerd=$TERMINAL_RELAY_CONTAINERD_VERSION" \
        "docker.io=$TERMINAL_RELAY_DOCKER_VERSION" \
        "prometheus-node-exporter=$TERMINAL_RELAY_NODE_EXPORTER_VERSION" \
        "runc=$TERMINAL_RELAY_RUNC_VERSION" \
        "ufw=$TERMINAL_RELAY_UFW_VERSION"
    /usr/bin/apt-mark hold \
        containerd docker.io prometheus-node-exporter runc ufw >/dev/null
    /usr/bin/systemctl enable --now docker.service
}

normalize_operator_keys() {
    local operator_key="$TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY"

    /usr/bin/install -d -o root -g root -m 0700 /root/.ssh
    install_content "$operator_key" "$root_keys" root root 0600

    if /usr/bin/getent passwd "$runtime_user" >/dev/null; then
        /usr/bin/install -d -o "$runtime_user" -g "$runtime_user" -m 0700 \
            "/home/$runtime_user/.ssh"
        install_content "$operator_key" "$runtime_keys" "$runtime_user" "$runtime_user" 0600
    fi
}

render_node_exporter_unit() {
    /usr/bin/sed \
        -e "s|@WORKER_NAME@|$worker_name|g" \
        -e "s|@TAILSCALE_IPV4@|$tailscale_ipv4|g" \
        "$node_exporter_template"
}

configure_node_exporter() {
    local rendered

    rendered="$(render_node_exporter_unit)"
    install_content "$rendered" "$node_exporter_unit" root root 0644
    /usr/bin/systemctl disable --now prometheus-node-exporter.service >/dev/null 2>&1 || true
    /usr/bin/systemctl mask prometheus-node-exporter.service >/dev/null
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemd-analyze verify "$node_exporter_unit"
    /usr/bin/systemctl enable --now node-exporter.service
}

configure_security_metrics() {
    install_binary_file \
        "$security_metrics_collector" \
        "$security_metrics_collector_path" \
        root root 0755
    install_binary_file \
        "$security_metrics_service" \
        "$security_metrics_service_unit" \
        root root 0644
    install_binary_file \
        "$security_metrics_timer" \
        "$security_metrics_timer_unit" \
        root root 0644
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemd-analyze verify \
        "$security_metrics_service_unit" \
        "$security_metrics_timer_unit"
    /usr/bin/systemctl start terminal-relay-security-metrics.service
    /usr/bin/systemctl enable --now terminal-relay-security-metrics.timer
}

configure_firewall() {
    /usr/sbin/ufw --force reset >/dev/null
    /usr/sbin/ufw default deny incoming >/dev/null
    /usr/sbin/ufw default allow outgoing >/dev/null
    /usr/sbin/ufw default deny routed >/dev/null
    /usr/sbin/ufw logging low >/dev/null
    /usr/sbin/ufw allow 41641/udp >/dev/null
    /usr/sbin/ufw allow in on tailscale0 \
        from "$TERMINAL_RELAY_MONITOR_IPV4" \
        to "$tailscale_ipv4" port 9100 proto tcp >/dev/null
    /usr/sbin/ufw allow in on tailscale0 \
        from "$TERMINAL_RELAY_MONITOR_IPV6" \
        to "$tailscale_ipv6" port 9100 proto tcp >/dev/null
    /usr/sbin/ufw allow in on tailscale0 \
        from "$TERMINAL_RELAY_DESKTOP_IPV4" \
        to "$tailscale_ipv4" port 9100 proto tcp >/dev/null
    /usr/sbin/ufw allow in on tailscale0 \
        from "$TERMINAL_RELAY_DESKTOP_IPV6" \
        to "$tailscale_ipv6" port 9100 proto tcp >/dev/null
    /usr/sbin/ufw --force enable >/dev/null
}

disable_host_openssh() {
    /usr/bin/systemctl disable --now ssh.service ssh.socket >/dev/null 2>&1 || true
    /usr/bin/systemctl mask ssh.service ssh.socket >/dev/null
}

write_state() {
    /usr/bin/install -d -o root -g root -m 0755 "$state_directory"
    install_content "$TERMINAL_RELAY_BASELINE_VERSION" "$state_version_file" root root 0644
    install_content "$worker_name" "$state_name_file" root root 0644
}

package_version_is() {
    local package="$1"
    local expected="$2"

    [[ "$(/usr/bin/dpkg-query -W -f='${Version}' "$package" 2>/dev/null)" == "$expected" ]] \
        || fail "$package does not match baseline version $expected."
}

verify_operator_keys() {
    local fingerprint

    [[ -f "$root_keys" && ! -L "$root_keys" ]] \
        || fail "Root authorized_keys is missing or unsafe."
    [[ "$(<"$root_keys")" == "$TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY" ]] \
        || fail "Root authorized_keys differs from the shared operator key."
    fingerprint="$(/usr/bin/ssh-keygen -lf "$root_keys" -E sha256 \
        | /usr/bin/awk 'NR == 1 { print $2 }')"
    [[ "$fingerprint" == "$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT" ]] \
        || fail "Root operator-key fingerprint mismatch."

    if /usr/bin/getent passwd "$runtime_user" >/dev/null; then
        [[ -f "$runtime_keys" && ! -L "$runtime_keys" ]] \
            || fail "Runtime authorized_keys is missing or unsafe."
        [[ "$(<"$runtime_keys")" == "$TERMINAL_RELAY_OPERATOR_AUTHORIZED_KEY" ]] \
            || fail "Runtime authorized_keys differs from the shared operator key."
        [[ "$(/usr/bin/stat -c '%U:%G:%a' "$runtime_keys")" \
            == "$runtime_user:$runtime_user:600" ]] \
            || fail "Runtime authorized_keys ownership or mode is incorrect."
    fi
}

verify_firewall() {
    local status

    status="$(/usr/sbin/ufw status verbose)"
    printf '%s\n' "$status" | /bin/grep -Fqx 'Status: active' \
        || fail "UFW is not active."
    printf '%s\n' "$status" | /bin/grep -Fq 'Logging: on (low)' \
        || fail "UFW logging differs from the baseline."
    printf '%s\n' "$status" | /bin/grep -Fq 'Default: deny (incoming), allow (outgoing), deny (routed)' \
        || fail "UFW defaults differ from the baseline."
    printf '%s\n' "$status" | /bin/grep -Fq '41641/udp' \
        || fail "UFW is missing the Tailscale UDP rule."
    printf '%s\n' "$status" | /bin/grep -Fq "$TERMINAL_RELAY_MONITOR_IPV4" \
        || fail "UFW is missing the monitoring IPv4 rule."
    printf '%s\n' "$status" | /bin/grep -Fq "$TERMINAL_RELAY_MONITOR_IPV6" \
        || fail "UFW is missing the monitoring IPv6 rule."
    printf '%s\n' "$status" | /bin/grep -Fq "$TERMINAL_RELAY_DESKTOP_IPV4" \
        || fail "UFW is missing the Terminal Relay desktop IPv4 rule."
    printf '%s\n' "$status" | /bin/grep -Fq "$TERMINAL_RELAY_DESKTOP_IPV6" \
        || fail "UFW is missing the Terminal Relay desktop IPv6 rule."
}

verify_node_exporter() {
    local rendered
    local temporary_unit

    rendered="$(render_node_exporter_unit)"
    temporary_unit="$(/usr/bin/mktemp /tmp/terminal-relay-node-exporter.XXXXXX)"
    printf '%s\n' "$rendered" > "$temporary_unit"
    /usr/bin/cmp -s "$temporary_unit" "$node_exporter_unit" \
        || {
            /bin/rm -f -- "$temporary_unit"
            fail "node-exporter.service differs from the baseline."
        }
    /bin/rm -f -- "$temporary_unit"
    /usr/bin/systemctl is-enabled --quiet node-exporter.service \
        || fail "node-exporter.service is not enabled."
    /usr/bin/systemctl is-active --quiet node-exporter.service \
        || fail "node-exporter.service is not active."
    [[ "$(/usr/bin/systemctl is-enabled prometheus-node-exporter.service 2>/dev/null)" == "masked" ]] \
        || fail "The broad apt node exporter service is not masked."
}

verify_security_metrics() {
    local destination
    local metric
    local mode
    local source

    for metric in \
        "$security_metrics_collector:$security_metrics_collector_path:755" \
        "$security_metrics_service:$security_metrics_service_unit:644" \
        "$security_metrics_timer:$security_metrics_timer_unit:644"; do
        IFS=: read -r source destination mode <<< "$metric"
        [[ -f "$destination" && ! -L "$destination" ]] \
            || fail "Security-metrics managed file is missing or unsafe: $destination"
        /usr/bin/cmp -s "$source" "$destination" \
            || fail "Security-metrics managed file differs from the baseline: $destination"
        [[ "$(/usr/bin/stat -c '%U:%G:%a' "$destination")" == "root:root:$mode" ]] \
            || fail "Security-metrics managed file ownership or mode is incorrect: $destination"
    done

    /usr/bin/systemctl is-enabled --quiet terminal-relay-security-metrics.timer \
        || fail "terminal-relay-security-metrics.timer is not enabled."
    /usr/bin/systemctl is-active --quiet terminal-relay-security-metrics.timer \
        || fail "terminal-relay-security-metrics.timer is not active."
    [[ "$(/usr/bin/systemctl show -p Result --value terminal-relay-security-metrics.service)" == success ]] \
        || fail "terminal-relay-security-metrics.service did not complete successfully."

    [[ -f "$security_metrics_file" && ! -L "$security_metrics_file" ]] \
        || fail "Fleet security metrics are missing or unsafe."
    [[ "$(/usr/bin/stat -c '%U:%G:%a' "$security_metrics_file")" == root:root:644 ]] \
        || fail "Fleet security metrics ownership or mode is incorrect."
    /bin/grep -Fqx \
        "fleet_tailscale_version_info{version=\"$TERMINAL_RELAY_TAILSCALE_VERSION\"} 1" \
        "$security_metrics_file" \
        || fail "Fleet Tailscale version metric differs from the baseline."
    /bin/grep -Fqx 'fleet_tailscale_security_update_required 0' "$security_metrics_file" \
        || fail "Fleet Tailscale security-update metric is not healthy."
    /bin/grep -Eq '^fleet_tailscale_auto_update_enabled [01]$' "$security_metrics_file" \
        || fail "Fleet Tailscale auto-update metric is invalid."
    /bin/grep -Eq '^fleet_reboot_required [01]$' "$security_metrics_file" \
        || fail "Fleet reboot-required metric is invalid."
}

verify_host() {
    local held
    local os_hostname

    validate_tailscale_identity
    package_version_is tailscale "$TERMINAL_RELAY_TAILSCALE_VERSION"
    package_version_is docker.io "$TERMINAL_RELAY_DOCKER_VERSION"
    package_version_is containerd "$TERMINAL_RELAY_CONTAINERD_VERSION"
    package_version_is runc "$TERMINAL_RELAY_RUNC_VERSION"
    package_version_is prometheus-node-exporter "$TERMINAL_RELAY_NODE_EXPORTER_VERSION"
    package_version_is ufw "$TERMINAL_RELAY_UFW_VERSION"
    /usr/bin/systemctl is-enabled --quiet tailscaled.service \
        || fail "tailscaled.service is not enabled."
    /usr/bin/systemctl is-active --quiet tailscaled.service \
        || fail "tailscaled.service is not active."
    /usr/bin/systemctl is-enabled --quiet docker.service \
        || fail "docker.service is not enabled."
    /usr/bin/systemctl is-active --quiet docker.service \
        || fail "docker.service is not active."
    [[ "$(/usr/bin/systemctl is-enabled ssh.service 2>/dev/null)" == "masked" ]] \
        || fail "ssh.service is not masked."
    [[ "$(/usr/bin/systemctl is-enabled ssh.socket 2>/dev/null)" == "masked" ]] \
        || fail "ssh.socket is not masked."
    verify_operator_keys
    verify_firewall
    verify_node_exporter
    verify_security_metrics

    held="$(/usr/bin/apt-mark showhold)"
    for package in tailscale docker.io containerd runc prometheus-node-exporter ufw; do
        printf '%s\n' "$held" | /bin/grep -Fqx "$package" \
            || fail "$package is not held at its baseline version."
    done

    if /usr/bin/getent passwd "$runtime_user" >/dev/null; then
        ! /usr/bin/id -nG "$runtime_user" | /usr/bin/tr ' ' '\n' | /bin/grep -Fqx docker \
            || fail "$runtime_user must not have Docker socket authority."
    fi
    [[ -f "$state_version_file" && "$(<"$state_version_file")" \
        == "$TERMINAL_RELAY_BASELINE_VERSION" ]] \
        || fail "Host baseline state is missing or stale."
    [[ -f "$state_name_file" && "$(<"$state_name_file")" == "$worker_name" ]] \
        || fail "Host provider-name state is missing or stale."
    os_hostname="$(/bin/hostname)"
    [[ "$os_hostname" == "$worker_name" \
        || "$os_hostname" =~ ^terminal-relay-worker-[0-9a-f]{8}$ ]] \
        || fail "OS hostname is not a recognized Terminal Relay worker hostname."

    printf '%s\n' 'TERMINAL_RELAY_HOST_RESULT_V1'
    printf 'baseline=%s\n' "$TERMINAL_RELAY_BASELINE_VERSION"
    printf 'provider_name=%s\n' "$worker_name"
    printf 'os_hostname=%s\n' "$os_hostname"
    printf 'tailscale_ipv4=%s\n' "$tailscale_ipv4"
    printf 'tailscale_ipv6=%s\n' "$tailscale_ipv6"
    printf 'operator_key=%s\n' "$TERMINAL_RELAY_OPERATOR_KEY_FINGERPRINT"
    printf 'status=ready\n'
    printf '%s\n' 'TERMINAL_RELAY_HOST_RESULT_END'
}

reconcile_host() {
    install_tailscale_repository
    /usr/bin/tailscale set \
        --accept-risk=lose-ssh \
        --ssh=true \
        --hostname="$worker_name"
    validate_tailscale_identity
    ensure_private_reconcile_route
    install_host_packages
    normalize_operator_keys
    configure_security_metrics
    configure_node_exporter
    configure_firewall
    /usr/bin/timedatectl set-timezone UTC
    disable_host_openssh
    write_state
    verify_host
}

main() {
    local command="${1:-}"

    [[ "$EUID" -eq 0 ]] || fail "Run this installer as root."
    validate_platform
    case "$command" in
        enroll)
            [[ "$#" -eq 3 ]] || { usage >&2; exit 2; }
            worker_name="$2"
            validate_worker_name
            enroll_tailscale "$3"
            ;;
        reconcile)
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            worker_name="$2"
            validate_worker_name
            reconcile_host
            ;;
        verify)
            [[ "$#" -eq 2 ]] || { usage >&2; exit 2; }
            worker_name="$2"
            validate_worker_name
            verify_host
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
