#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/checks.sh"
check_debug=1
check_compile UVCDescriptorChecks \
    MacMicApp/UVCDescriptors.swift \
    Tests/UVCDescriptorChecks.swift
"$check_dir/UVCDescriptorChecks" "$project_root/Tests/Fixtures/yizhan-uvc-descriptors.jsonl"
