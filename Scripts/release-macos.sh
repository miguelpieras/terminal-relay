#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
version="${1:-}"
release_notes_file="${RELEASE_NOTES_FILE:-}"
development_team="${DEVELOPMENT_TEAM:-6EBZ756H9Q}"
signing_identity="${DEVELOPER_ID_APPLICATION:-Developer ID Application}"
bundle_version="${MACOS_BUNDLE_VERSION:-$(git -C "$repository_root" show -s --format=%ct HEAD)}"
appcast_url="https://miguelpieras.github.io/terminal-relay/appcast.xml"
download_url_prefix="https://github.com/miguelpieras/terminal-relay/releases/download/v${version}/"
derived_data="$repository_root/DerivedData"
release_root="$repository_root/build/macos-release"
archive_path="$release_root/TerminalRelay.xcarchive"
archived_app="$archive_path/Products/Applications/Terminal Relay.app"
staged_app="$release_root/Terminal Relay.app"
update_archive="$release_root/Terminal-Relay-${version}.zip"
release_notes_asset="$release_root/Terminal-Relay-${version}.md"
appcast_path="$release_root/appcast.xml"
pages_directory="$release_root/pages"
temporary_directory="$(mktemp -d)"

cleanup() {
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT

usage() {
    echo "Usage: RELEASE_NOTES_FILE=/path/to/notes.md ./Scripts/release-macos.sh VERSION"
}

[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    usage >&2
    exit 64
}
[[ "$bundle_version" =~ ^[1-9][0-9]*$ ]] || {
    echo "release-macos: MACOS_BUNDLE_VERSION must be a positive integer" >&2
    exit 64
}
[[ -n "$release_notes_file" && -f "$release_notes_file" && ! -L "$release_notes_file" ]] || {
    echo "release-macos: RELEASE_NOTES_FILE must name a regular Markdown file" >&2
    exit 64
}
[[ -n "${APPLE_API_KEY_PATH:-}" && -f "$APPLE_API_KEY_PATH" && ! -L "$APPLE_API_KEY_PATH" ]] || {
    echo "release-macos: APPLE_API_KEY_PATH must name the App Store Connect private key" >&2
    exit 64
}
[[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]] || {
    echo "release-macos: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID are required" >&2
    exit 64
}

branch="$(git -C "$repository_root" branch --show-current)"
[[ -z "$branch" || "$branch" == main ]] || {
    echo "release-macos: releases must be built from main" >&2
    exit 1
}
[[ -z "$(git -C "$repository_root" status --porcelain)" ]] || {
    echo "release-macos: commit or remove working-tree changes first" >&2
    exit 1
}
git -C "$repository_root" fetch --quiet origin main
head_commit="$(git -C "$repository_root" rev-parse HEAD)"
main_commit="$(git -C "$repository_root" rev-parse refs/remotes/origin/main)"
[[ "$head_commit" == "$main_commit" ]] || {
    echo "release-macos: HEAD must be the current origin/main commit" >&2
    exit 1
}

configured_version="$(
    /usr/bin/awk '
        /MARKETING_VERSION:/ {
            gsub(/"/, "", $2)
            print $2
            exit
        }
    ' "$repository_root/project.yml"
)"
[[ "$configured_version" == "$version" ]] || {
    echo "release-macos: tag version $version does not match MARKETING_VERSION $configured_version" >&2
    exit 1
}

downloaded_appcast="$temporary_directory/appcast.xml"
if /usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    "$appcast_url" \
    --output "$downloaded_appcast"; then
    latest_bundle_version="$(
        /usr/bin/python3 - "$downloaded_appcast" <<'PYTHON'
import re
import sys

contents = open(sys.argv[1], encoding="utf-8").read()
versions = [int(value) for value in re.findall(r'sparkle:version="([0-9]+)"', contents)]
print(max(versions) if versions else 0)
PYTHON
    )"
    [[ "$bundle_version" -gt "$latest_bundle_version" ]] || {
        echo "release-macos: bundle version $bundle_version must exceed published version $latest_bundle_version" >&2
        exit 1
    }
elif [[ "${FIRST_MACOS_RELEASE:-0}" != 1 ]]; then
    echo "release-macos: published appcast is unavailable; set FIRST_MACOS_RELEASE=1 only for the first release" >&2
    exit 1
fi

"$script_directory/check-public-repo.sh"
"$repository_root/Server/Tests/terminal-relay-session-tests.sh"
"$repository_root/Server/Tests/install-worker-session-helper-generation-tests.sh"
"$repository_root/Server/Tests/worker-lifecycle-tests.sh"

cd "$repository_root"
xcodegen generate
xcodebuild -quiet \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$bundle_version" \
    test

case "$release_root" in
    "$repository_root"/build/macos-release) ;;
    *) echo "release-macos: refusing unexpected release path" >&2; exit 1 ;;
esac
/bin/rm -rf "$release_root"
/bin/mkdir -p "$release_root"
if [[ -s "$downloaded_appcast" ]]; then
    /bin/cp "$downloaded_appcast" "$appcast_path"
fi

xcodebuild -quiet \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$bundle_version" \
    DEVELOPMENT_TEAM="$development_team" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    archive

[[ -d "$archived_app" && ! -L "$archived_app" ]] || {
    echo "release-macos: signed archive did not contain Terminal Relay.app" >&2
    exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$archived_app"
/usr/bin/ditto "$archived_app" "$staged_app"

notary_archive="$temporary_directory/Terminal-Relay-notarization.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$notary_archive"
xcrun notarytool submit "$notary_archive" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait
xcrun stapler staple "$staged_app"
xcrun stapler validate "$staged_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staged_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$staged_app"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$update_archive"
/bin/cp "$release_notes_file" "$release_notes_asset"

generate_appcast="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_update="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$generate_appcast" && -x "$sign_update" ]] || {
    echo "release-macos: Sparkle signing tools were not resolved" >&2
    exit 1
}

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    /usr/bin/printf '%s\n' "$SPARKLE_PRIVATE_KEY" \
        | "$generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "$download_url_prefix" \
            --embed-release-notes \
            --maximum-deltas 0 \
            --versions "$bundle_version" \
            -o "$appcast_path" \
            "$release_root"
    /usr/bin/printf '%s\n' "$SPARKLE_PRIVATE_KEY" \
        | "$sign_update" --verify --ed-key-file - "$appcast_path"
else
    "$generate_appcast" \
        --account "${SPARKLE_KEY_ACCOUNT:-terminal-relay}" \
        --download-url-prefix "$download_url_prefix" \
        --embed-release-notes \
        --maximum-deltas 0 \
        --versions "$bundle_version" \
        -o "$appcast_path" \
        "$release_root"
    "$sign_update" \
        --verify \
        --account "${SPARKLE_KEY_ACCOUNT:-terminal-relay}" \
        "$appcast_path"
fi

/usr/bin/grep -q 'sparkle:edSignature=' "$appcast_path" || {
    echo "release-macos: generated appcast is missing an EdDSA signature" >&2
    exit 1
}
/bin/mkdir -p "$pages_directory"
/bin/cp "$appcast_path" "$pages_directory/appcast.xml"

echo "Created notarized macOS release artifacts:"
echo "  $update_archive"
echo "  $release_notes_asset"
echo "  $appcast_path"
