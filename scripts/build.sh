#!/bin/bash
# Builds the iOS app for the iOS Simulator using the Sate scheme.
# Matches Xcode's Cmd+R by sharing the standard DerivedData build cache.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
DEVICE="${SATE_DEVICE:-iPhone 17 Pro}"
OS="${SATE_OS:-26.5}"
DESTINATION="${SATE_DESTINATION:-platform=iOS Simulator,name=${DEVICE},OS=${OS}}"

xcodebuild -project Sate.xcodeproj -scheme Sate -configuration "$CONFIG" \
    -destination "$DESTINATION" build "${@:2}" | \
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

TARGET_BUILD_DIR=$(xcodebuild -project Sate.xcodeproj -scheme Sate -configuration "$CONFIG" \
    -destination "$DESTINATION" -showBuildSettings | awk -F ' = ' '/^ *TARGET_BUILD_DIR =/ {print $2}')
APP_PATH="${TARGET_BUILD_DIR}/Sate.app"

test -d "$APP_PATH"
mkdir -p build
ln -sfn "$TARGET_BUILD_DIR" "build/${CONFIG}-iphonesimulator"
echo "App: $APP_PATH"
