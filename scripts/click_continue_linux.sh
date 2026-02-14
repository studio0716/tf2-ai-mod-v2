#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
SHOT_DIR="/tmp"
SHOT_FILE="$SHOT_DIR/tf2_menu_${TS}.png"

log() { echo "[click-linux] $*"; }

WIN_ID="$(xdotool search --name "Transport Fever 2" 2>/dev/null | head -1 || true)"
if [ -z "$WIN_ID" ]; then
  log "No TF2 window found; cannot click Continue."
  exit 1
fi

xdotool windowactivate "$WIN_ID" || true
sleep 0.8

# Capture screenshot before click so we can calibrate coords later.
if command -v gnome-screenshot >/dev/null 2>&1; then
  gnome-screenshot -f "$SHOT_FILE" >/dev/null 2>&1 || true
elif command -v maim >/dev/null 2>&1; then
  maim "$SHOT_FILE" >/dev/null 2>&1 || true
elif command -v scrot >/dev/null 2>&1; then
  scrot "$SHOT_FILE" >/dev/null 2>&1 || true
elif command -v import >/dev/null 2>&1; then
  import -window root "$SHOT_FILE" >/dev/null 2>&1 || true
else
  SHOT_FILE=""
fi

X="${TF2_CONTINUE_X:-960}"
Y="${TF2_CONTINUE_Y:-540}"

log "Clicking Continue at ($X,$Y) in window $WIN_ID"
xdotool mousemove --window "$WIN_ID" "$X" "$Y"
sleep 0.2
xdotool click 1
sleep 0.35
xdotool click 1

if [ -n "$SHOT_FILE" ] && [ -f "$SHOT_FILE" ]; then
  log "Saved pre-click screenshot: $SHOT_FILE"
fi

exit 0
