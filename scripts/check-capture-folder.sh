#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile CaptureFolderChecks \
    MacMicApp/CameraDevice.swift \
    MacMicApp/VideoMode.swift \
    MacMicApp/CapturePreferences.swift \
    Tests/CaptureFolderChecks.swift
"$check_dir/CaptureFolderChecks" "$project_root/.local/build/Checks"
