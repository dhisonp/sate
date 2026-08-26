#!/bin/bash
# Build -> boot -> install -> launch -> screenshot, driving the simulator through
# simctl (see scripts/build.sh for why xcodebuild destinations are avoided).
#
# Launches with SATE_MOCK=1 so the app replays a bundled SSE fixture instead of
# calling Cloudflare; this exercises streaming, coalescing, persistence and the
# error states with no token and no network.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="com.dhison.sate"
OUT="artifacts"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
[ -n "$UDID" ] || { echo "No simulator named '$DEVICE'"; exit 1; }
echo "Device: $DEVICE ($UDID)"

./scripts/build.sh Debug

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "build/Debug-iphonesimulator/Sate.app"
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    --console-pty > "$OUT/launch.log" 2>&1 &
LAUNCH_PID=$!
sleep 4
xcrun simctl io "$UDID" screenshot "$OUT/01-launch.png" >/dev/null 2>&1
echo "Screenshot: $OUT/01-launch.png"
kill $LAUNCH_PID 2>/dev/null || true
