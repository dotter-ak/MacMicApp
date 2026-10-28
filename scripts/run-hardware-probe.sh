#!/bin/bash
# Run after build-local.sh. Quits/relaunches MacMicApp and leaves the preview open.
# Usage: run-hardware-probe.sh [--uvc] [--ui [--inspector]] 'Camera name' [format-index exact-fps]
set -euo pipefail
uvc_enabled=false
ui_enabled=false
inspector_enabled=false
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --uvc) uvc_enabled=true ;;
        --ui) ui_enabled=true ;;
        --inspector) inspector_enabled=true ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
if [[ $# != 1 && $# != 3 ]]; then
    printf 'Usage: %s [--uvc] [--ui [--inspector]] CAMERA_NAME [FORMAT_INDEX FPS]\n' "$0" >&2
    exit 2
fi
if [[ "$inspector_enabled" == true && "$ui_enabled" != true ]] || [[ "$ui_enabled" == true && $# != 1 ]]; then
    printf 'Use --inspector with --ui; UI measurements use the saved mode without a format override.\n' >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/.local/build/Debug/MacMicApp.app"
[[ -d "$app_path" ]] || { printf 'Build the app first.\n' >&2; exit 1; }
# Launch Services can fail to redirect a sandboxed app into an external volume.
report_dir="$(mktemp -d /private/tmp/macmic-probe.XXXXXX)"
args=(--hardware-probe --probe-camera "$1")
if [[ "$uvc_enabled" == true ]]; then args+=(--probe-uvc); fi
if [[ "$ui_enabled" == true ]]; then args+=(--probe-ui-modes); fi
if [[ "$inspector_enabled" == true ]]; then args+=(--probe-inspector); fi
if [[ $# == 3 ]]; then args+=(--probe-format "$2" --probe-fps "$3"); fi
osascript -e 'if application "MacMicApp" is running then tell application "MacMicApp" to quit'
# App termination awaits camera teardown; allow Launch Services to observe exit.
for ((attempt=0; attempt<50; attempt++)); do
    if ! pgrep -x MacMicApp >/dev/null; then break; fi
    sleep 0.1
done
if pgrep -x MacMicApp >/dev/null; then
    printf 'MacMicApp did not quit; no second process was launched.\n' >&2
    exit 1
fi
open "$app_path" --stdout "$report_dir/report.jsonl" --stderr "$report_dir/stderr.log" --args "${args[@]}"
printf 'Report: %s/report.jsonl\n' "$report_dir"
for ((attempt=0; attempt<45; attempt++)); do
    if [[ -f "$report_dir/report.jsonl" ]] && grep -q '"event":"result"' "$report_dir/report.jsonl"; then
        tail -1 "$report_dir/report.jsonl"
        exit 0
    fi
    sleep 1
done
printf 'No result after 45 seconds. Check the app and %s.\n' "$report_dir" >&2
exit 1
