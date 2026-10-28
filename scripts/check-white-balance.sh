#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile WhiteBalanceChecks \
    MacMicApp/UVCImageControls.swift \
    MacMicApp/UVCExposure.swift \
    MacMicApp/CameraControl.swift \
    MacMicApp/UVCBrightness.swift \
    Tests/WhiteBalanceChecks.swift \
    Tests/ControlWriteTestSupport.swift
"$check_dir/WhiteBalanceChecks"
