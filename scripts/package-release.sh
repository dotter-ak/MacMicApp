#!/bin/bash
set -euo pipefail
if [[ $# != 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "${MACMIC_BUILD_ROOT:-}" != "$project_root" || -z "${MACMIC_BUILD_NUMBER:-}" ]]; then
    exec python3 "$project_root/scripts/lib/build-number.py" "$project_root" bash "$project_root/scripts/package-release.sh"
fi
# Always build first: never distribute an old binary after editing the sources.
bash "$project_root/scripts/build-local.sh" Release
python3 "$project_root/scripts/lib/package-release.py" "$project_root"
