#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile FrameTimingChecks \
    MacMicApp/FrameTiming.swift \
    Tests/FrameTimingChecks.swift
"$check_dir/FrameTimingChecks"
