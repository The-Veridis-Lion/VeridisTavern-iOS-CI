#!/usr/bin/env bash
# Build an unsigned simulator app from the prepared TauriTavern checkout.
set -euo pipefail

if [[ $# != 2 ]]; then
    echo 'Usage: bash bench-m2/ci-ios/build.sh <TauriTavern checkout> <output directory>' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'This build requires an arm64 macOS runner.' >&2
    exit 2
fi

checkout="$(cd "$1" && pwd -P)"
mkdir -p "$2"
output="$(cd "$2" && pwd -P)"
apple="$checkout/src-tauri/crates/tauritavern/gen/apple"
[[ -f "$apple/tauritavern.xcodeproj/project.pbxproj" ]]

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_27.2.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    echo 'Xcode 27.2 is missing. Use the arm64 xcode-27 runner or set DEVELOPER_DIR.' >&2
    exit 2
fi
sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "${sdk%%.*}" -lt 27 ]]; then
    echo "Need the iOS 27 SDK that builds the existing Apple host, found $sdk." >&2
    exit 2
fi
xcodebuild -version

cd "$checkout"
rustup target add aarch64-apple-ios-sim
pnpm install --frozen-lockfile
export TAURITAVERN_IOS_POLICY_PROFILE=full
unset TAURITAVERN_SKIP_WEB_BUILD
# The locked CLI starts the options server used by the checked-in Xcode build
# phase. For this target it extracts the .app directly from the simulator
# archive instead of exporting an IPA. 'build' also embeds frontendDist in Debug.
node scripts/tauri-app.mjs --prepare-frontend ios build --ci --debug \
    --target aarch64-sim --no-sign --features devtools-pilot -- --locked

built_app="$apple/build/arm64-sim/TauriTavern.app"
plist="$built_app/Info.plist"
if [[ ! -f "$plist" ]]; then
    echo "Expected the simulator .app at $built_app" >&2
    exit 3
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
platform="$(/usr/libexec/PlistBuddy -c 'Print CFBundleSupportedPlatforms:0' "$plist")"
if [[ "$bundle_id" != com.tauritavern.client || "$platform" != iPhoneSimulator ||
    "$(xcrun lipo -archs "$built_app/$executable")" != arm64 ]]; then
    echo 'The build did not produce the expected arm64 simulator application.' >&2
    exit 3
fi

app="$output/TauriTavern.app"
archive="$output/M2-iOS-Simulator.zip"
if [[ -e "$app" || -e "$archive" ]]; then
    echo 'Use a fresh output directory to avoid mixing application bundles.' >&2
    exit 3
fi
ditto "$built_app" "$app"
ditto -c -k --keepParent "$app" "$archive"
printf 'app=%s\nzip=%s\nbundle_id=%s\n' "$app" "$archive" "$bundle_id"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'app=%s\nzip=%s\nbundle_id=%s\n' "$app" "$archive" "$bundle_id" >> "$GITHUB_OUTPUT"
fi
