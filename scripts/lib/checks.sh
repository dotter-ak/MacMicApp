#!/bin/bash
# Sourced by focused checks; this file does not launch a test on its own.
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check_dir="$project_root/.local/build/Checks"
config="$project_root/Config/App.xcconfig"
check_config() { awk -F ' = ' -v key="$1" '$1 == key { print $2; exit }' "$config"; }

capture_sources=(
    MacMicApp/DeliveryFPS.swift
    MacMicApp/FrameSnapshot.swift
    MacMicApp/FrameRateMonitor.swift
    MacMicApp/CapturePreferences.swift
    MacMicApp/CameraDevice.swift
    MacMicApp/VideoMode.swift
    MacMicApp/UVCImageControls.swift
    MacMicApp/UVCExposure.swift
    MacMicApp/CameraControl.swift
    MacMicApp/UVCBrightness.swift
    MacMicApp/UVCControlConnection.swift
    MacMicApp/UVCDescriptors.swift
    MacMicApp/CaptureEngine.swift
    MacMicApp/CameraControlQueue.swift
    MacMicApp/CaptureController.swift
    MacMicApp/CameraAdjustments.swift
)

check_compile() {
    local name="$1"
    shift
    local sources=() source
    for source in "$@"; do sources+=("$project_root/$source"); done
    local swift_version="$(check_config SWIFT_VERSION)"
    local flags=(-parse-as-library -swift-version "${swift_version%.0}" -strict-concurrency=complete)
    if [[ "${check_debug:-0}" == 1 ]]; then flags+=(-D DEBUG); fi
    mkdir -p "$check_dir" "$project_root/.local/build/ModuleCache"
    xcrun --sdk macosx swiftc "${flags[@]}" \
        -target "$(check_config ARCHS)-apple-macos$(check_config MACOSX_DEPLOYMENT_TARGET)" \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -module-cache-path "$project_root/.local/build/ModuleCache" \
        "${sources[@]}" -o "$check_dir/$name"
}
