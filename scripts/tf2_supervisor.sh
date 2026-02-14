#!/bin/bash
# =============================================================================
# TF2 AI Supervisor - Process manager for the autonomous TF2 system
# Usage: tf2_supervisor.sh {start|stop|restart-game|full-restart|dashboard|status|agent-start|agent-stop|agent-status|agent-restart}
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="/tmp/tf2_orchestrator.pid"
LOG_FILE="/tmp/tf2_orchestrator.log"
AGENT_PID_FILE="/tmp/tf2_agent.pid"
AGENT_HEARTBEAT="/tmp/tf2_agent_heartbeat"

# Platform-aware game launch
if [[ "$(uname)" == "Darwin" ]]; then
  LAUNCH_CMD="open steam://run/1066780"
  CLICK_CMD="python3 $SCRIPT_DIR/click_menu.py"
else
  export DISPLAY="${DISPLAY:-:0}"
  STEAM_BIN="$(command -v steam 2>/dev/null || true)"
  if [ -z "$STEAM_BIN" ] && [ -x /snap/bin/steam ]; then
    STEAM_BIN="/snap/bin/steam"
  fi
  LAUNCH_CMD="${STEAM_BIN:-steam} steam://run/1066780"
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

  # Kill existing TF2 process (force kill requested for reliability)
  pkill -9 -f "TransportFever2" 2>/dev/null || true
  pkill -9 -f "Transport Fever 2" 2>/dev/null || true
  sleep 3

  echo "[supervisor] Launching TF2 via Steam..."
  if [[ "$(uname)" == "Darwin" ]]; then
    $LAUNCH_CMD
  else
    nohup bash -lc "$LAUNCH_CMD" >/tmp/tf2_steam_launch.log 2>&1 &
    disown || true
  fi
  echo "[supervisor] Waiting for game window (13s)..."
  sleep 13

  echo "[supervisor] Clicking Continue to load save..."
  if [[ "$(uname)" == "Darwin" ]]; then
    $CLICK_CMD
  else
    if $CLICK_CMD; then
      echo "[supervisor] Click helper completed."
    else
      echo "[supervisor] WARN: Linux click helper failed. Click Continue manually."
    fi
  fi

  echo "[supervisor] Waiting for save to load (13s)..."
  sleep 13
  echo "[supervisor] Game should be loaded."
}

start_agent() {
  if [ -f "$AGENT_PID_FILE" ] && kill -0 "$(cat "$AGENT_PID_FILE")" 2>/dev/null; then
    echo "[supervisor] Agent already running (PID $(cat "$AGENT_PID_FILE"))"
    return 0
  fi

  echo "[supervisor] Starting agent service..."
  PYTHONUNBUFFERED=1 python3 "$REPO_DIR/python/agent_service.py" &
  echo $! > "$AGENT_PID_FILE"
  echo "[supervisor] Agent started (PID $(cat "$AGENT_PID_FILE"))"
}

stop_agent() {
  if [ -f "$AGENT_PID_FILE" ]; then
    PID=$(cat "$AGENT_PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo "[supervisor] Stopping agent (PID $PID)..."
      kill "$PID"
      # Wait up to 10s for graceful shutdown
      for i in $(seq 1 10); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 1
      done
      # Force kill if still alive
      kill -0 "$PID" 2>/dev/null && kill -9 "$PID"
    fi
    rm -f "$AGENT_PID_FILE"
    echo "[supervisor] Agent stopped."
  else
    echo "[supervisor] No agent PID file found."
  fi
}

show_agent_status() {
  echo "=== Agent Service Status ==="

  if [ -f "$AGENT_PID_FILE" ] && kill -0 "$(cat "$AGENT_PID_FILE")" 2>/dev/null; then
    echo "Agent:     RUNNING (PID $(cat "$AGENT_PID_FILE"))"
  else
    echo "Agent:     STOPPED"
  fi

  # Heartbeat age
  if [ -f "$AGENT_HEARTBEAT" ]; then
    HEARTBEAT=$(cat "$AGENT_HEARTBEAT" 2>/dev/null)
    NOW=$(date +%s)
    AGE=$((NOW - HEARTBEAT))
    echo "Heartbeat: ${AGE}s ago"
    if [ "$AGE" -gt 600 ]; then
      echo "  WARNING: Heartbeat is stale (>10 min)"
    fi
  else
    echo "Heartbeat: none"
  fi

  # Chat port check
  if command -v curl >/dev/null 2>&1; then
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null | grep -q "200"; then
      echo "Chat:      http://localhost:8080"
    else
      echo "Chat:      not responding"
    fi
  fi
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

  # Agent service
  if [ -f "$AGENT_PID_FILE" ] && kill -0 "$(cat "$AGENT_PID_FILE")" 2>/dev/null; then
    echo "Agent:        RUNNING (PID $(cat "$AGENT_PID_FILE"))"
  else
    echo "Agent:        STOPPED"
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
  agent-start)
    start_agent
    ;;
  agent-stop)
    stop_agent
    ;;
  agent-status)
    show_agent_status
    ;;
  agent-restart)
    stop_agent
    start_agent
    ;;
  *)
    echo "Usage: $0 {start|stop|restart-game|full-restart|dashboard|status|agent-start|agent-stop|agent-status|agent-restart}"
    exit 1
    ;;
esac
