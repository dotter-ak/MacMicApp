#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile CaptureControllerChecks \
    "${capture_sources[@]}" \
    MacMicApp/CameraPreview.swift \
    Tests/CaptureControllerChecks.swift
"$check_dir/CaptureControllerChecks"
