#!/bin/bash
set -euo pipefail
configuration="${1:-Debug}"
if [[ $# -gt 1 || ( "$configuration" != Debug && "$configuration" != Release ) ]]; then
    printf 'Usage: %s [Debug|Release]\n' "$0" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/.local/build/$configuration/MacMicApp.app"
if [[ ! -d "$app_path" ]]; then
    printf 'Build the app first with scripts/build-local.sh %s.\n' "$configuration" >&2
    exit 1
fi
codesign --verify --strict "$app_path"
# Notify Launch Services about the updated bundle, including its native icon.
# Only this app is registered; no global Dock or icon-cache reset.
touch "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
open "$app_path"
