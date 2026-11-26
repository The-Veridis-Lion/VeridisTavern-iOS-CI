#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

mode="${1-}"
case "$mode" in replay|frames) ;; *) exit 2 ;; esac
public_temp="${RUNNER_TEMP:?}"
public_report="$public_temp/vt-public-report.enc"
here="$(cd "$(dirname "$0")" && pwd -P)"
exec 3>&1
private_root="$(mktemp -d "$public_temp/vt-ios-private.XXXXXXXX")"
exec >"$private_root/run.log" 2>&1
stage=setup

cleanup() {
    local status=$? sim id
    set +e
    for sim in "$private_root"/m2-sim/udid "$private_root"/measurement-*/m2-sim/udid; do
        [[ -f "$sim" ]] || continue
        IFS= read -r id <"$sim"
        if [[ "$id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
            xcrun simctl shutdown "$id" || true
            xcrun simctl delete "$id" || true
        fi
    done
    if [[ -n "$private_root" && "$private_root" == "$public_temp"/vt-ios-private.* ]]; then
        rm -rf -- "$private_root"
    fi
    if ((status != 0)); then
        printf '::error::iOS replay stage %s\n' "$stage" >&3
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Only the wrapper can write to the public progress channel.
quiet() { "$@" 3>&-; }

# Keep private commands away from the public runner's writable workflow files.
unset GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY
unset vt_report_key
vt_report_key="${VT_REPORT_KEY-}"
unset VT_REPORT_KEY
[[ -n "$vt_report_key" ]]
[[ ! -e "$public_report" ]]
export RUNNER_TEMP="$private_root"
mkdir -p "$private_root/trusted" "$private_root/numeric-results"
control="$private_root/control"
case_root="$private_root/case"

stage=control-download
quiet python3 "$here/archive.py" fetch VT_CONTROL_URL "${VT_CONTROL_SHA256-}" "$control" "$private_root/trusted/control.zip"
unset VT_CONTROL_URL
stage=fixture-download
quiet python3 "$here/archive.py" fetch VT_FIXTURE_URL "${FIXTURE_SHA256-}" "$case_root" "$private_root/trusted/fixtures.zip"
unset VT_FIXTURE_URL
export FIXTURE_SHA="$FIXTURE_SHA256"

stage=inputs
[[ -f "$control/bench-m2/ci-ios/report.py" && -f "$case_root/m2-private/ios/127.0.0.1/fixtures.json" ]]
if [[ "$mode" == frames ]]; then
    [[ "${VT_IOS_FRAME_MODE-}" =~ ^(timing|screen|diagnostic|stream-profile|stream-input|stream-abc|listener-regression|listener-acceptance|tail-c|tail-native-c|tail-product-c|tail-product-abc)$ && "${PAIR-}" =~ ^[1-5]$ ]]
    if [[ "$VT_IOS_FRAME_MODE" == stream-* ]]; then
        [[ "${FIRST-}" =~ ^After@[0-9]+$ ]]
        if [[ "$VT_IOS_FRAME_MODE" == stream-abc ]]; then
            [[ "${VT_IOS_C_ONLY-}" == 0 && "${SECOND-}" =~ ^StreamTrial@[0-9]+$ ]]
        else
            [[ "${VT_IOS_C_ONLY-}" == 1 && ( -z "${SECOND-}" || "${SECOND-}" =~ ^StreamTrial@[0-9]+$ ) ]]
        fi
    elif [[ "$VT_IOS_FRAME_MODE" == listener-regression || "$VT_IOS_FRAME_MODE" == listener-acceptance || "$VT_IOS_FRAME_MODE" == tail-c ]]; then
        [[ "${FIRST-}" =~ ^(M2|ListenerFix)@[0-9]+$ && "${SECOND-}" =~ ^(M2|ListenerFix)@[0-9]+$ ]]
        if [[ "$VT_IOS_FRAME_MODE" == tail-c ]]; then [[ "${VT_IOS_C_ONLY-}" == 1 ]]; else [[ "${VT_IOS_C_ONLY-}" != 1 ]]; fi
        [[ "${FIRST%@*}" != "${SECOND%@*}" && "${FIRST#*@}" == "${SECOND#*@}" ]]
    else
        [[ "${FIRST-}" =~ ^(M2|After)@[0-9]+$ ]]
        if [[ "$VT_IOS_FRAME_MODE" == tail-product-c ]]; then
            [[ "${VT_IOS_C_ONLY-}" == 1 && "${FIRST-}" =~ ^M2@[0-9]+$ && "${SECOND-}" =~ ^After@[0-9]+$ && "${FIRST#*@}" != "${SECOND#*@}" ]]
        elif [[ "${VT_IOS_C_ONLY-}" == 1 ]]; then
            [[ ( "$VT_IOS_FRAME_MODE" == diagnostic || "$VT_IOS_FRAME_MODE" == tail-native-c ) && -z "${SECOND-}" ]]
        else
            [[ "${SECOND-}" =~ ^(M2|After)@[0-9]+$ && "${FIRST%@*}" != "${SECOND%@*}" ]]
        fi
    fi
else
    [[ "${VT_REPLAY_PHASE-}" =~ ^(fixed|ordinary|visible)$ && "${BUILD_VARIANT-}" =~ ^(M2|After)$ && "${BUILD_RUN-}" =~ ^[0-9]+$ ]]
fi
if [[ "$mode" == frames || "$VT_REPLAY_PHASE" != fixed ]]; then
    stage=tokenizer
    quiet npm install --prefix "$private_root/tokenizer" --ignore-scripts --no-audit --no-fund tiktoken@1.0.22
fi

status=0
if [[ "$mode" == frames ]]; then
    stage=frames
    quiet bash "$control/bench-m2/ci-ios/frame-series.sh" || status=$?
else
    stage=app-download
    mkdir -p "$private_root/build-artifact" "$private_root/m2-app" "$private_root/evidence"
    quiet gh run download "$BUILD_RUN" --repo "$GITHUB_REPOSITORY" -n "$BUILD_VARIANT-iOS-Simulator" --dir "$private_root/build-artifact"
    archive="$private_root/build-artifact/$BUILD_VARIANT-iOS-Simulator.zip"
    if [[ "$BUILD_VARIANT" != M2 ]]; then
        ln -s "$archive" "$private_root/build-artifact/M2-iOS-Simulator.zip"
    fi
    quiet ditto -x -k "$archive" "$private_root/m2-app"
    stage=simulator
    quiet bash "$control/bench-m2/ci-ios/simulator.sh" "$private_root/m2-app/TauriTavern.app" "$private_root/m2-sim"
    stage=replay
    export VT_REPLAY_TIKTOKEN_ROOT="$private_root/tokenizer"
    quiet bash "$control/bench-m2/ci-ios/run-replay.sh" "$case_root" "$private_root/m2-sim" "$private_root/evidence" || status=$?
    quiet python3 "$control/bench-m2/ci-ios/report.py" "$private_root" "$private_root/numeric-results/M2-iOS-result.json" || status=$?
fi

stage=report-encryption
quiet python3 "$here/archive.py" bundle "$mode" "$private_root/numeric-results" "$private_root/trusted/numeric.zip"
openssl_bin="$(command -v openssl)"
if command -v brew >/dev/null; then
    brew_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [[ -n "$brew_prefix" && -x "$brew_prefix/bin/openssl" ]]; then openssl_bin="$brew_prefix/bin/openssl"; fi
fi
printf '%s\n' "$vt_report_key" | quiet "$openssl_bin" enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -pass stdin \
    -in "$private_root/trusted/numeric.zip" -out "$private_root/trusted/numeric.enc"
unset vt_report_key
mv "$private_root/trusted/numeric.enc" "$public_report"
stage=checks
exit "$status"
