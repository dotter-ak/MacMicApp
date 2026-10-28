#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile CameraStoreChecks \
    MacMicApp/VideoMode.swift \
    MacMicApp/CapturePreferences.swift \
    MacMicApp/CameraDevice.swift \
    MacMicApp/CameraProvider.swift \
    MacMicApp/CameraStore.swift \
    Tests/CameraStoreChecks.swift
"$check_dir/CameraStoreChecks"
