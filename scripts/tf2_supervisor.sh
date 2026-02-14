#!/bin/bash
# =============================================================================
# TF2 AI Supervisor - Process manager for the autonomous TF2 system
# Usage: tf2_supervisor.sh {start|stop|restart-game|full-restart|dashboard|status}
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="/tmp/tf2_orchestrator.pid"
LOG_FILE="/tmp/tf2_orchestrator.log"

# Platform-aware game launch
if [[ "$(uname)" == "Darwin" ]]; then
  LAUNCH_CMD="open steam://run/1066780"
  CLICK_CMD="python3 $SCRIPT_DIR/click_menu.py"
else
  export DISPLAY="${DISPLAY:-:0}"
  LAUNCH_CMD="steam steam://run/1066780"
  CLICK_CMD="$SCRIPT_DIR/click_continue_linux.sh"
fi

start_orchestrator() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[supervisor] Orchestrator already running (PID $(cat "$PID_FILE"))"
    return 0
  fi

  echo "[supervisor] Starting orchestrator..."
  PYTHONUNBUFFERED=1 python3 "$REPO_DIR/python/orchestrator.py" \
    --cycles 0 --log-file "$LOG_FILE" &
  echo $! > "$PID_FILE"
  echo "[supervisor] Orchestrator started (PID $(cat "$PID_FILE"))"
}

stop_orchestrator() {
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "[supervisor] Stopping orchestrator (PID $PID)..."
      kill "$PID"
      # Wait up to 10s for graceful shutdown
      for i in $(seq 1 10); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 1
      done
      # Force kill if still alive
      kill -0 "$PID" 2>/dev/null && kill -9 "$PID"
    fi
    rm -f "$PID_FILE"
    echo "[supervisor] Orchestrator stopped."
  else
    echo "[supervisor] No PID file found."
  fi
}

restart_game() {
  echo "[supervisor] Restarting Transport Fever 2..."

  # Kill existing TF2 process
  pkill -f "TransportFever2" 2>/dev/null || true
  pkill -f "Transport Fever 2" 2>/dev/null || true
  sleep 3

  echo "[supervisor] Launching TF2 via Steam..."
  $LAUNCH_CMD
  echo "[supervisor] Waiting for game window (20s)..."
  sleep 20

  echo "[supervisor] Clicking Continue to load save..."
  if [[ "$(uname)" == "Darwin" ]]; then
    $CLICK_CMD
  else
    # Linux: use xdotool to find window and click Continue
    # The coordinates may need calibration for your resolution
    WINDOW_ID=$(xdotool search --name "Transport Fever 2" 2>/dev/null | head -1)
    if [ -n "$WINDOW_ID" ]; then
      xdotool windowactivate "$WINDOW_ID"
      sleep 1
      # Click the Continue button (center of screen, adjust as needed)
      # Default 1080p coordinates - calibrate with: xdotool getmouselocation
      xdotool mousemove --window "$WINDOW_ID" 960 540
      sleep 0.5
      xdotool click 1
      sleep 0.5
      xdotool click 1
      echo "[supervisor] Clicked Continue."
    else
      echo "[supervisor] WARN: Could not find TF2 window. Click Continue manually."
    fi
  fi

  echo "[supervisor] Waiting for save to load (30s)..."
  sleep 30
  echo "[supervisor] Game should be loaded."
}

show_dashboard() {
  if [ -f "$LOG_FILE" ]; then
    echo "=== TF2 AI Dashboard ==="
    # Show the most recent dashboard block
    grep -A 20 "METRICS DASHBOARD" "$LOG_FILE" | tail -25
    echo ""
    # Show latest cycle result
    echo "=== Latest Cycles ==="
    grep "^\[cycle" "$LOG_FILE" | tail -5
  else
    echo "No log file found at $LOG_FILE"
  fi
}

show_status() {
  echo "=== TF2 AI Status ==="

  # Orchestrator
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Orchestrator: RUNNING (PID $(cat "$PID_FILE"))"
  else
    echo "Orchestrator: STOPPED"
  fi

  # TF2 game
  if pgrep -f "TransportFever2" >/dev/null 2>&1; then
    echo "TF2 Game:     RUNNING (PID $(pgrep -f "TransportFever2" | head -1))"
  else
    echo "TF2 Game:     STOPPED"
  fi

  # Latest cycle info from log
  if [ -f "$LOG_FILE" ]; then
    LAST_LINE=$(grep "^\[cycle" "$LOG_FILE" | tail -1)
    if [ -n "$LAST_LINE" ]; then
      echo "Last cycle:   $LAST_LINE"
    fi
  fi

  # OpenClaw
  if pgrep -f "openclaw" >/dev/null 2>&1; then
    echo "OpenClaw:     RUNNING"
  else
    echo "OpenClaw:     STOPPED"
  fi
}

case "${1:-}" in
  start)
    start_orchestrator
    ;;
  stop)
    stop_orchestrator
    ;;
  restart-game)
    restart_game
    ;;
  full-restart)
    stop_orchestrator
    restart_game
    start_orchestrator
    ;;
  dashboard)
    show_dashboard
    ;;
  status)
    show_status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart-game|full-restart|dashboard|status}"
    exit 1
    ;;
esac
