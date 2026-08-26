#!/bin/bash
# End-to-end verification in the simulator: build -> boot -> install -> launch ->
# drive -> screenshot, driving everything through simctl.
#
# Two things worth knowing about this script:
#
# 1. It never uses `xcodebuild -destination`. On this machine Xcode 26.6 ships
#    the iOS 26.5 SDK but only the 26.2 simulator runtime is installed, and
#    xcodebuild's destination resolver then refuses to enumerate ANY simulator.
#    scripts/build.sh sidesteps that with -target/-sdk.
#
# 2. It drives the app with SATE_DEMO rather than synthetic taps. Coordinate
#    clicking against the Simulator window is brittle and silently wrong when the
#    window is moved or rescaled; a launch-argument hook is deterministic.
#    SATE_MOCK=1 replays a bundled SSE fixture through the REAL SSEParser and
#    ChatCompletionsCodec, so no Cloudflare token and no network are needed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="com.dhison.sate"
OUT="artifacts"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
[ -n "$UDID" ] || { echo "No simulator named '$DEVICE'"; exit 1; }
echo "Device: $DEVICE ($UDID)"

./scripts/build.sh Debug

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "build/Debug-iphonesimulator/Sate.app"

# simctl passes environment to the app only via the SIMCTL_CHILD_ prefix.
shoot () {  # prompt, output, seconds-to-wait
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    SIMCTL_CHILD_SATE_MOCK=1 \
    SIMCTL_CHILD_SATE_DEMO="${1:+1}" \
    SIMCTL_CHILD_SATE_DEMO_PROMPT="$1" \
        xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
    sleep "$3"
    xcrun simctl io "$UDID" screenshot "$OUT/$2" >/dev/null 2>&1
    echo "  $OUT/$2"
}

echo "Capturing:"
shoot ""                                            01-launch.png      4
shoot "Explain Server-Sent Events for streaming."   03-streaming.png   2
shoot "Explain Server-Sent Events for streaming."   04-complete.png    10
shoot "Please trigger an error path now"            05-error.png       9
shoot "Please truncate this response"               06-truncated.png   9
shoot "Simulate unauthorized token"                 07-unauthorized.png 8
echo "Done. Review the PNGs in $OUT/."
