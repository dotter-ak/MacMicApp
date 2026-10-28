#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile VideoModeChecks \
    MacMicApp/VideoMode.swift \
    Tests/VideoModeChecks.swift
"$check_dir/VideoModeChecks"
