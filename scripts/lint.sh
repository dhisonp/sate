#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftlint &> /dev/null; then
    echo "Error: swiftlint not found. Please install it (e.g., brew install swiftlint)."
    exit 1
fi

echo "Running SwiftLint..."
swiftlint
