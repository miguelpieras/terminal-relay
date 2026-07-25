#!/bin/bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
derived_data="$repository_root/DerivedData"
source_app="$derived_data/Build/Products/Release/Terminal Relay.app"
installed_app="/Applications/Terminal Relay.app"
staged_app="$derived_data/Install/Terminal Relay.app"
build_number="$(/bin/date -u +%s)"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$repository_root"

echo "Checking public repository hygiene"
"$repository_root/Scripts/check-public-repo.sh"

echo "Running worker tests"
"$repository_root/Server/Tests/terminal-relay-session-tests.sh"
"$repository_root/Server/Tests/install-worker-session-helper-generation-tests.sh"
"$repository_root/Server/Tests/worker-lifecycle-tests.sh"

echo "Regenerating Terminal Relay.xcodeproj"
xcodegen generate

echo "Running Terminal Relay tests"
xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$build_number" \
    test

echo "Running Terminal Relay iOS tests"
ios_simulator_id=$(/usr/bin/python3 - <<'PYTHON'
import json
import subprocess

devices = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
)["devices"]
for runtime in sorted(devices, reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator")
PYTHON
)
xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelayIOS \
    -destination "platform=iOS Simulator,id=$ios_simulator_id" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$build_number" \
    test

echo "Building Terminal Relay Release"
xcodebuild \
    -project TerminalRelay.xcodeproj \
    -scheme TerminalRelay \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$build_number" \
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
    if /usr/bin/pgrep -x "Terminal Relay" >/dev/null; then
        /usr/bin/pkill -KILL -x "Terminal Relay"
    fi
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

if [[ -d "$installed_app" ]]; then
    /usr/bin/find "$installed_app" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +
else
    /bin/mkdir -p "$installed_app"
fi
/usr/bin/ditto "$staged_app" "$installed_app"

unregistered_duplicate=false
for build_app in \
    "$derived_data/Build/Products/Debug/Terminal Relay.app" \
    "$derived_data/Build/Products/Release/Terminal Relay.app" \
    "$staged_app"
do
    if [[ -d "$build_app" ]]; then
        "$launch_services" -u "$build_app" >/dev/null 2>&1 || true
        unregistered_duplicate=true
    fi
done

while IFS= read -r duplicate_app; do
    if [[ "$duplicate_app" != "$installed_app" && "$(basename "$duplicate_app")" == "Terminal Relay.app" ]]; then
        "$launch_services" -u "$duplicate_app" >/dev/null 2>&1 || true
        unregistered_duplicate=true
    fi
done < <(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.mpieras.TerminalRelay"c')

"$launch_services" -f "$installed_app"

dock_result="$(/usr/bin/swift "$repository_root/Scripts/pin-to-dock.swift")"
if [[ "$dock_result" == "added" || "$dock_result" == "refreshed" || "$unregistered_duplicate" == "true" ]]; then
    /usr/bin/killall Dock 2>/dev/null || true
fi

/usr/bin/open "$installed_app"

echo "Installed and launched $installed_app"
