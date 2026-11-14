#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$project_root/Tests/BuildNumberChecks.py"
