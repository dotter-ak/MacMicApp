#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile WindowAndSleepChecks \
    MacMicApp/WindowState.swift \
    MacMicApp/SleepPrevention.swift \
    Tests/WindowAndSleepChecks.swift
"$check_dir/WindowAndSleepChecks"
