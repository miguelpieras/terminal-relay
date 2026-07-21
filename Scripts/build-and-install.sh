#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
derived_data="$repository_root/DerivedData"
source_app="$derived_data/Build/Products/Release/Terminal Relay.app"
installed_app="/Applications/Terminal Relay.app"
staged_app="$derived_data/Install/Terminal Relay.app"

cd "$repository_root"

echo "Regenerating Terminal Relay.xcodeproj"
xcodegen generate

echo "Running Terminal Relay tests"
xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    test

echo "Building Terminal Relay Release"
xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "$source_app" ]]; then
    echo "Build product was not found at $source_app" >&2
    exit 1
fi

if /usr/bin/pgrep -x "Terminal Relay" >/dev/null; then
    /usr/bin/pkill -TERM -x "Terminal Relay"
    for _ in 1 2 3 4 5; do
        /usr/bin/pgrep -x "Terminal Relay" >/dev/null || break
        /bin/sleep 1
    done
fi

if [[ "$(dirname "$installed_app")" != "/Applications" || "$(basename "$installed_app")" != "Terminal Relay.app" ]]; then
    echo "Refusing to install to unexpected path: $installed_app" >&2
    exit 1
fi

/bin/rm -rf "$staged_app"
/bin/mkdir -p "$(dirname "$staged_app")"
/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --force --deep --sign - "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

/bin/rm -rf "$installed_app"
/usr/bin/ditto "$staged_app" "$installed_app"

dock_result="$(/usr/bin/swift "$repository_root/Scripts/pin-to-dock.swift")"
if [[ "$dock_result" == "added" ]]; then
    /usr/bin/killall Dock 2>/dev/null || true
fi

/usr/bin/open "$installed_app"

echo "Installed and launched $installed_app"
