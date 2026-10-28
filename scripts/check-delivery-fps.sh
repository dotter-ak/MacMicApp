#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile DeliveryFPSChecks \
    MacMicApp/DeliveryFPS.swift \
    Tests/DeliveryFPSChecks.swift
"$check_dir/DeliveryFPSChecks"
