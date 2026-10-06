#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Evidence
# The default suite contains no production network writer or privileged-service registration.
swift test -j 4 2>&1 | tee Evidence/tests.log
