#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile CameraControlChecks \
    "${capture_sources[@]}" \
    Tests/CameraControlChecks.swift \
    Tests/ControlWriteTestSupport.swift
"$check_dir/CameraControlChecks"
