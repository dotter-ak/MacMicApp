#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile FramePNGChecks \
    MacMicApp/FrameSnapshot.swift \
    Tests/FramePNGChecks.swift
"$check_dir/FramePNGChecks" "$project_root/.local/build/Checks"
