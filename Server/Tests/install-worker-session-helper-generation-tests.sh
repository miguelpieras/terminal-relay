#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
installer="$repository_root/Scripts/install-worker-session-helper.sh"
remote_lock_path="/run/lock/terminal-relay-session-helper.lock"

[[ -f "$installer" && ! -L "$installer" ]] \
    || { echo "Missing regular installer: $installer" >&2; exit 66; }

# Load only the installer's command-rendering helpers; do not run its SSH path.
# shellcheck disable=SC1090
source <(/usr/bin/awk '
    /^quote_remote\(\)/ { copying = 1 }
    /^validate_ssh_target / { copying = 0 }
    copying { print }
' "$installer")

install_script="$(/usr/bin/sed -n "/<<'REMOTE_INSTALL'/,/^REMOTE_INSTALL$/p" "$installer" \
    | /usr/bin/sed '1d;$d')"
rollback_script="$(/usr/bin/sed -n "/<<'REMOTE_ROLLBACK'/,/^REMOTE_ROLLBACK$/p" "$installer" \
    | /usr/bin/sed '1d;$d')"

[[ "$install_script" == *'case "$staged_path" in'* \
    && "$install_script" == *'"$source_digest"'* \
    && "$install_script" == *'"$install_result"'* ]] \
    || { echo "Install renderer expanded or lost literal remote variables." >&2; exit 1; }
[[ "$rollback_script" == *'case "$staged" in'* \
    && "$rollback_script" == *'"$expected_digest"'* \
    && "$rollback_script" == *'"$install_result"'* ]] \
    || { echo "Rollback renderer expanded or lost literal remote variables." >&2; exit 1; }

machine_id=00000000000000000000000000000000
host_name=terminal-relay-generation-test
digest=0000000000000000000000000000000000000000000000000000000000000000

for admin_uid in 0 1000; do
    install_command="$(build_locked_remote_command \
        "$admin_uid" "$install_script" terminal-relay-install "$machine_id" "$host_name")"
    rollback_command="$(build_locked_remote_command \
        "$admin_uid" "$rollback_script" terminal-relay-rollback \
        "$machine_id" "$host_name" "$digest" 1:2:3 new '')"
    validate_remote_rendering install "$install_script" "$install_command"
    validate_remote_rendering rollback "$rollback_script" "$rollback_command"
done

echo "PASS: worker helper remote command generation"
