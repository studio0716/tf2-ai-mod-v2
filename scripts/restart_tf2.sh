#!/bin/bash
# Fast restart script for TF2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Killing Transport Fever 2..."
pkill -9 -f "TransportFever2"
pkill -9 "Transport Fever 2"
sleep 2

echo "Launching via Steam..."
open "steam://run/1066780"

echo "Waiting for game window (15s)..."
sleep 15

echo "Clicking Continue to load save..."
python3 "$SCRIPT_DIR/click_menu.py"

echo "Waiting for save to load (30s)..."
sleep 30

echo "Done. Game should be loaded."
