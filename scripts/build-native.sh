#!/bin/bash
set -euo pipefail
configuration="${1:-Debug}"
if [[ $# -gt 1 || ( "$configuration" != Debug && "$configuration" != Release ) ]]; then
    printf 'Usage: %s [Debug|Release]\n' "$0" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! xcrun --find actool >/dev/null 2>&1; then
    printf 'Native Liquid Glass icons require full Xcode. Select Xcode with xcode-select or DEVELOPER_DIR, then rerun this script.\n' >&2
    exit 2
fi
xcodebuild -project "$project_root/MacMicApp.xcodeproj" -scheme MacMicApp \
    -configuration "$configuration" -derivedDataPath "$project_root/.local/build/Native" \
    -destination 'platform=macOS,arch=arm64' "CODE_SIGN_IDENTITY=${MACMIC_SIGN_IDENTITY:--}" build
printf 'Built with native icon: %s/.local/build/Native/Build/Products/%s/MacMicApp.app\n' "$project_root" "$configuration"
