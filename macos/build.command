#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-macos.sh universal
open dist
