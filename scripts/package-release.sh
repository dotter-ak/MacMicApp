#!/bin/bash
set -euo pipefail
if [[ $# != 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Always build first: never distribute an old binary after editing the sources.
bash "$project_root/scripts/build-local.sh" Release
python3 "$project_root/scripts/lib/package-release.py" "$project_root"
