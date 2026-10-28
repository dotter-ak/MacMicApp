#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile ResetAdjustmentsChecks \
    "${capture_sources[@]}" \
    Tests/ResetAdjustmentsChecks.swift
"$check_dir/ResetAdjustmentsChecks"
