#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile ExposureChecks \
    Tools/UVCExposureTrial.swift \
    MacMicApp/UVCExposure.swift \
    MacMicApp/CameraControl.swift \
    MacMicApp/UVCBrightness.swift \
    Tests/ExposureChecks.swift \
    Tests/ControlWriteTestSupport.swift
"$check_dir/ExposureChecks"
