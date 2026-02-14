#!/bin/bash
# =============================================================================
# TF2 AI Watchdog - Cron job to restart dead processes
# Runs every 5 minutes via crontab.
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/tmp/tf2_watchdog.log"
export DISPLAY="${DISPLAY:-:0}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Check orchestrator
PID_FILE="/tmp/tf2_orchestrator.pid"
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if ! kill -0 "$PID" 2>/dev/null; then
    log "Orchestrator (PID $PID) is dead. Restarting..."
    "$SCRIPT_DIR/tf2_supervisor.sh" start
  fi
else
  log "No PID file. Starting orchestrator..."
  "$SCRIPT_DIR/tf2_supervisor.sh" start
fi

# Check TF2 game process
if ! pgrep -f "TransportFever2" >/dev/null 2>&1; then
  log "TF2 not running. Doing full restart..."
  "$SCRIPT_DIR/tf2_supervisor.sh" full-restart
fi

# Trim watchdog log (keep last 200 lines)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ]; then
  tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
