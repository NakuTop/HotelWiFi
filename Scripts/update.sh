#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/env python3 "$PROJECT_DIR/Scripts/update.py"
