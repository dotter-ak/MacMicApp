#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p output
xcodebuild -version
xcrun actool AppIcon.icon --compile output --platform macosx \
  --target-device mac --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist output/icon-info.plist \
  --output-format human-readable-text --warnings --errors
python3 icon-resources.py stamp AppIcon.icon output
