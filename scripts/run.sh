#!/bin/bash
# Builds, installs and launches Sate in the iOS Simulator with live mode (SATE_MOCK=0).
#
# Derived from scripts/e2e.sh: builds via build.sh (avoiding xcodebuild -destination
# SDK skew issues), boots the target simulator if needed, installs the app,
# and launches it connected to real Keychain credentials and live network.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="com.dhison.sate"

# Find booted device first, or fallback to matching device name
UDID=$(xcrun simctl list devices | grep -F " (Booted)" | head -1 \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" || true)

if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 \
        | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" || true)
fi

[ -n "$UDID" ] || { echo "No simulator available for '$DEVICE'"; exit 1; }
echo "Target Simulator: $DEVICE ($UDID)"

./scripts/build.sh "$CONFIGURATION"

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
