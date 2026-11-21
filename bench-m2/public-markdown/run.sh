#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 || ! -f "$1/Info.plist" || ! -f "$2/Info.plist" || -e "$3" ]]; then
    echo 'Usage: bash run.sh <M2 TauriTavern.app> <After TauriTavern.app> <new result.json>' >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd -P)"
m2="$(cd "$1" && pwd -P)"
after="$(cd "$2" && pwd -P)"
output="$3"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_27.2.app/Contents/Developer}"
bundle_id=com.tauritavern.client
state="$(mktemp -d "${TMPDIR:-/tmp}/tt-markdown.XXXXXXXX")"
socket=''
udid=''

cleanup() {
    if [[ -s "$state/udid" ]]; then read -r udid < "$state/udid"; fi
    if [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
        xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    fi
    if [[ "$socket" == /tmp/vtios.*/tauri-pilot-com.tauritavern.client.sock ]]; then
        rm -f "$socket"
        rmdir "${socket%/*}" 2>/dev/null || true
    fi
    rm -f "$state/udid" "$state/simulator.json" "$state"/block-{1,2,3,4}.json
    rmdir "$state" 2>/dev/null || true
}
trap cleanup EXIT

for app in "$m2" "$after"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")" == "$bundle_id" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleSupportedPlatforms:0' "$app/Info.plist")" == iPhoneSimulator ]]
done

GITHUB_OUTPUT='' VT_IOS_FRAME_MODE='' VT_IOS_SIM_RUST_LOG=warn bash "$here/../ci-ios/simulator.sh" "$m2" "$state" >/dev/null
read -r udid < "$state/udid"
socket="$(node -p 'require(process.argv[1]).pilotSocket' "$state/simulator.json")"
[[ "$socket" =~ ^/tmp/vtios\.[A-Za-z0-9]+/tauri-pilot-com\.tauritavern\.client\.sock$ ]]

reinstall() {
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null
    xcrun simctl uninstall "$udid" "$bundle_id" >/dev/null
    rm -f "$socket"
    xcrun simctl install "$udid" "$1" >/dev/null
    SIMCTL_CHILD_XDG_RUNTIME_DIR="${socket%/*}" SIMCTL_CHILD_RUST_LOG=warn \
        xcrun simctl launch "$udid" "$bundle_id" >/dev/null
    local deadline=$((SECONDS + 40))
    until [[ -S "$socket" ]]; do
        if (( SECONDS >= deadline )); then echo 'The new Simulator app did not start Pilot.' >&2; return 3; fi
        sleep 1
    done
}

# Balanced order on one newly created device. Uninstalling clears the app data between blocks.
node "$here/benchmark.mjs" block M2 "$state/simulator.json" > "$state/block-1.json"
reinstall "$after"
node "$here/benchmark.mjs" block After "$state/simulator.json" > "$state/block-2.json"
reinstall "$after"
node "$here/benchmark.mjs" block After "$state/simulator.json" > "$state/block-3.json"
reinstall "$m2"
node "$here/benchmark.mjs" block M2 "$state/simulator.json" > "$state/block-4.json"
node "$here/benchmark.mjs" compare "$state"/block-{1,2,3,4}.json > "$output"
