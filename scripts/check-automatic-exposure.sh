#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_compile AutomaticExposureChecks \
    "${capture_sources[@]}" \
    Tests/AutomaticExposureChecks.swift
"$check_dir/AutomaticExposureChecks"
