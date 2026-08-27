#!/bin/bash
# End-to-end verification in the simulator: build -> boot -> install -> launch ->
# drive -> screenshot, driving everything through simctl.
#
# It drives the app with SATE_DEMO rather than synthetic taps. Coordinate
# clicking against the Simulator window is brittle and silently wrong when the
# window is moved or rescaled; a launch-argument hook is deterministic.
# SATE_MOCK=1 replays a bundled SSE fixture through the REAL SSEParser and
# ChatCompletionsCodec, so no Cloudflare token and no network are needed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
OS="${SATE_OS:-26.5}"
BUNDLE_ID="com.dhison.sate"
OUT="artifacts"
mkdir -p "$OUT"

UDID=$(python3 -c '
import json, subprocess, sys
device_name = sys.argv[1]
runtime_target = sys.argv[2]
try:
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
    devices_by_runtime = data.get("devices", {})
    target_key = next((k for k in devices_by_runtime if runtime_target in k), None)

    if target_key:
        for d in devices_by_runtime[target_key]:
            if d["name"] == device_name and d["state"] == "Booted":
                print(d["udid"])
                sys.exit(0)
        for d in devices_by_runtime[target_key]:
            if d["name"] == device_name:
                print(d["udid"])
                sys.exit(0)

    for rk, devs in devices_by_runtime.items():
        for d in devs:
            if d["name"] == device_name and d["state"] == "Booted":
                print(d["udid"])
                sys.exit(0)

    for rk, devs in devices_by_runtime.items():
        for d in devs:
            if d["name"] == device_name:
                print(d["udid"])
                sys.exit(0)
except Exception:
    pass
' "$DEVICE" "iOS-${OS//./-}")

[ -n "$UDID" ] || { echo "No simulator named '$DEVICE'"; exit 1; }
echo "Device: $DEVICE ($UDID) [iOS $OS]"

SATE_DEVICE="$DEVICE" SATE_OS="$OS" ./scripts/build.sh Debug

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
