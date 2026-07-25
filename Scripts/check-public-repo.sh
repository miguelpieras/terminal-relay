#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"

fail() {
    printf 'check-public-repo: %s\n' "$*" >&2
    exit 1
}

for forbidden_path in \
    Server/worker-baseline.env \
    Server/worker-baseline.local.env \
    docs/workers.md; do
    [[ -e "$repository_root/$forbidden_path" ]] \
        && git -C "$repository_root" ls-files --error-unmatch "$forbidden_path" \
            >/dev/null 2>&1 \
        && fail "private path is tracked: $forbidden_path"
done

while IFS= read -r private_path; do
    [[ ! -e "$repository_root/$private_path" ]] \
        || fail "private planning file is tracked: $private_path"
done < <(git -C "$repository_root" ls-files | grep -E '^(\\.private|dev-tasklists)/' || true)

secret_pattern='(AKIA|ASIA)[A-Z0-9]{16}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|tskey-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----'
public_files=()
while IFS= read -r -d '' file; do
    public_files+=("$file")
done < <(git -C "$repository_root" ls-files --cached --others --exclude-standard -z)

for relative_path in "${public_files[@]}"; do
    [[ "$relative_path" != Scripts/check-public-repo.sh ]] || continue
    path="$repository_root/$relative_path"
    [[ -f "$path" && ! -L "$path" ]] || continue
    /usr/bin/grep -Iq . "$path" || continue

    if /usr/bin/grep -Eq "$secret_pattern" "$path"; then
        fail "possible credential in $relative_path"
    fi
    if /usr/bin/grep -E '/Users/' "$path" \
        | /usr/bin/grep -Ev '/Users/(developer|runner)/' >/dev/null; then
        fail "personal filesystem path in $relative_path"
    fi
    if /usr/bin/grep -Eq \
        'TERMINAL_RELAY_(PROVIDER_PROJECT_ID|PROVIDER_FIREWALL_ID)="[0-9]+"' \
        "$path"; then
        fail "provider resource identifier in $relative_path"
    fi
done

for manifest in \
    TerminalRelay/PrivacyInfo.xcprivacy \
    TerminalRelayIOS/PrivacyInfo.xcprivacy; do
    /usr/bin/plutil -lint "$repository_root/$manifest" >/dev/null \
        || fail "invalid privacy manifest: $manifest"
done

echo "Public repository checks passed."
