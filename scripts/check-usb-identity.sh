#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile USBIdentityChecks \
    MacMicApp/UVCDescriptors.swift \
    Tests/USBIdentityChecks.swift
"$check_dir/USBIdentityChecks"
