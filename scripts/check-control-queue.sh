#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile CameraControlQueueChecks \
    MacMicApp/CameraControlQueue.swift \
    MacMicApp/CameraControl.swift \
    MacMicApp/UVCImageControls.swift \
    MacMicApp/UVCExposure.swift \
    MacMicApp/UVCBrightness.swift \
    Tests/CameraControlQueueChecks.swift
"$check_dir/CameraControlQueueChecks"
