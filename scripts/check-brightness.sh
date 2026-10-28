#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile BrightnessTrialChecks \
    MacMicApp/UVCBrightness.swift \
    Tests/BrightnessTrialChecks.swift \
    MacMicApp/BrightnessTrial.swift \
    MacMicApp/CameraControl.swift
"$check_dir/BrightnessTrialChecks"
