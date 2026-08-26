#!/bin/bash
# Builds the iOS app for the simulator.
#
# NOTE: we use `-target` + `-sdk iphonesimulator` rather than `-scheme` +
# `-destination`. On this machine Xcode 26.6 ships the iOS 26.5 SDK but only the
# iOS 26.2 simulator runtime is installed, and xcodebuild's scheme destination
# resolver refuses to enumerate ANY simulator as a result. The target-based
# invocation bypasses that resolver and builds correctly.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
xcodebuild -project Sate.xcodeproj -target Sate -configuration "$CONFIG" \
    -sdk iphonesimulator build "${@:2}" | \
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
test -d "build/${CONFIG}-iphonesimulator/Sate.app"
echo "App: build/${CONFIG}-iphonesimulator/Sate.app"
