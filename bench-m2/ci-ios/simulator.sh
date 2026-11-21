#!/usr/bin/env bash
# Launch the bundled app in a fresh simulator and publish its Pilot endpoint.
set -euo pipefail

if [[ $# != 2 || ! -f "$1/Info.plist" ]]; then
    echo 'Usage: bash bench-m2/ci-ios/simulator.sh <TauriTavern.app> <state directory>' >&2
    exit 2
fi
app="$(cd "$1" && pwd -P)"
mkdir -p "$2"
state="$(cd "$2" && pwd -P)"
if [[ -e "$state/udid" ]]; then
    echo 'Use a fresh simulator state directory.' >&2
    exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_27.2.app/Contents/Developer}"
runtime="${VT_IOS_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-2}"
device="${VT_IOS_SIM_DEVICE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
platform="$(/usr/libexec/PlistBuddy -c 'Print CFBundleSupportedPlatforms:0' "$app/Info.plist")"
if [[ "$bundle_id" != com.tauritavern.client || "$platform" != iPhoneSimulator ]]; then
    echo 'Provide the TauriTavern simulator .app from build.sh.' >&2
    exit 2
fi

udid="$(xcrun simctl create 'TauriTavern M2 CI' "$device" "$runtime")"
printf '%s\n' "$udid" > "$state/udid"
printf 'udid=%s\n' "$udid"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'udid=%s\n' "$udid" >> "$GITHUB_OUTPUT"
fi
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
if [[ "${VT_IOS_FRAME_MODE:-}" == diagnostic ]]; then
    # WebProcessProxy reads this integer when launching the iOS WebContent
    # process. Touch only the new simulator's domain before any app is opened.
    inspector_preference=unavailable
    if xcrun simctl spawn "$udid" defaults write com.apple.webinspectord RemoteInspectorEnabled -int 1 >/dev/null 2>&1; then
        if [[ "$(xcrun simctl spawn "$udid" defaults read com.apple.webinspectord RemoteInspectorEnabled 2>/dev/null || true)" == 1 ]]; then
            inspector_preference=enabled
        fi
        xcrun simctl spawn "$udid" notifyutil -p com.apple.webinspectord.enabled >/dev/null 2>&1 || true
    fi
    printf 'webkit_inspector_preference=%s\n' "$inspector_preference"
fi
xcrun simctl install "$udid" "$app"
container="$(xcrun simctl get_app_container "$udid" "$bundle_id" data)"

# CoreSimulator shares /tmp with the host. Use a private, short socket path
# so separate devices cannot contend for the same Pilot socket.
socket_dir="$(mktemp -d /tmp/vtios.XXXXXXXX)"
socket="$socket_dir/tauri-pilot-$bundle_id.sock"
printf 'container=%s\nbundle_id=%s\npilot_socket=%s\n' "$container" "$bundle_id" "$socket"
SIMCTL_CHILD_XDG_RUNTIME_DIR="$socket_dir" \
    SIMCTL_CHILD_RUST_LOG="${VT_IOS_SIM_RUST_LOG:-info,tauritavern::command=debug}" \
    xcrun simctl launch "$udid" "$bundle_id"

deadline=$((SECONDS + 40))
until [[ -S "$socket" ]]; do
    if (( SECONDS >= deadline )); then
        echo "Pilot did not create $socket after launch on $udid." >&2
        exit 3
    fi
    sleep 1
done

node - "$state/simulator.json" "$udid" "$container" "$bundle_id" "$socket" <<'JS'
const [file, udid, container, bundleId, pilotSocket] = process.argv.slice(2);
require('node:fs').writeFileSync(file, JSON.stringify({ udid, container, bundleId, pilotSocket }, null, 2) + '\n');
JS
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'container=%s\nbundle_id=%s\npilot_socket=%s\n' "$container" "$bundle_id" "$socket" >> "$GITHUB_OUTPUT"
fi
