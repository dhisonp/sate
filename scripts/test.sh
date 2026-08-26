#!/bin/bash
# Runs the SateCore unit suite on macOS. No simulator required: SateCore is
# Foundation-only by design, which is exactly what makes it testable this way.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
