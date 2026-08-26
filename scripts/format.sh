#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swiftformat &> /dev/null; then
    echo "Error: swiftformat not found. Please install it (e.g., brew install swiftformat)."
    exit 1
fi

echo "Running SwiftFormat..."
swiftformat .
