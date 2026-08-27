#!/bin/bash
# Builds, installs and launches Sate in the iOS Simulator with live mode (SATE_MOCK=0).
# Targets the iOS 26.5 simulator and shares Xcode's DerivedData build cache.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
OS="${SATE_OS:-26.5}"
BUNDLE_ID="com.dhison.sate"

# Find target device UDID prioritizing iOS 26.5
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

[ -n "$UDID" ] || { echo "No simulator available for '$DEVICE'"; exit 1; }
echo "Target Simulator: $DEVICE ($UDID) [iOS $OS]"

SATE_DEVICE="$DEVICE" SATE_OS="$OS" ./scripts/build.sh "$CONFIGURATION"

echo "Booting simulator if needed..."
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

echo "Installing $BUNDLE_ID..."
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "build/$CONFIGURATION-iphonesimulator/Sate.app"

echo "Launching Sate (live mode: SATE_MOCK=0)..."
SIMCTL_CHILD_SATE_MOCK=0 \
    xcrun simctl launch "$UDID" "$BUNDLE_ID"

open -a Simulator || true
echo "Sate is running in live mode."
