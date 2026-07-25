#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
archive_path="$repository_root/build/TerminalRelayIOS.xcarchive"
export_path="$repository_root/build/AppStore"
mode="${1:-export}"

case "$mode" in
    export)
        export_options="$repository_root/Distribution/AppStoreConnectExportOptions.plist"
        ;;
    upload)
        export_options="$repository_root/Distribution/AppStoreConnectUploadOptions.plist"
        ;;
    -h|--help)
        echo "Usage: ./Scripts/release-ios.sh [export|upload]"
        exit 0
        ;;
    *)
        echo "release-ios: expected export or upload" >&2
        exit 64
        ;;
esac

[[ "$(git -C "$repository_root" branch --show-current)" == main ]] \
    || { echo "release-ios: releases must be built from main" >&2; exit 1; }
[[ -z "$(git -C "$repository_root" status --porcelain)" ]] \
    || { echo "release-ios: commit or remove working-tree changes first" >&2; exit 1; }
[[ -f "$export_options" && ! -L "$export_options" ]] \
    || { echo "release-ios: missing export options" >&2; exit 1; }

"$script_directory/check-public-repo.sh"

cd "$repository_root"
xcodegen generate

case "$archive_path" in
    "$repository_root"/build/TerminalRelayIOS.xcarchive) ;;
    *) echo "release-ios: refusing unexpected archive path" >&2; exit 1 ;;
esac
case "$export_path" in
    "$repository_root"/build/AppStore) ;;
    *) echo "release-ios: refusing unexpected export path" >&2; exit 1 ;;
esac

/bin/rm -rf "$archive_path" "$export_path"

xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelayIOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive_path" \
    -allowProvisioningUpdates \
    archive

xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates

if [[ "$mode" == upload ]]; then
    echo "Uploaded Terminal Relay to App Store Connect."
else
    echo "Exported the App Store package to $export_path."
fi
