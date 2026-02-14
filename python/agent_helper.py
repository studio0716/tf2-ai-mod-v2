#!/usr/bin/env python3
"""
Agent Helper - CLI tool interface for the TF2 AI agent.

Claude Code calls this via its built-in Bash tool. Each command executes
a query or action, prints JSON to stdout, and exits.

Usage:
  python agent_helper.py game-state          # Current year, money, speed
  python agent_helper.py lines               # All transport lines
  python agent_helper.py industries          # All industries
  python agent_helper.py demands             # Town demands
  python agent_helper.py metrics             # Dashboard text
  python agent_helper.py decisions [N]       # Last N decisions (default 5)
  python agent_helper.py run-cycle           # Run one orchestrator cycle
  python agent_helper.py goals               # Show current goals
  python agent_helper.py update-goal ID KEY VALUE  # Update a goal field
  python agent_helper.py add-goal "desc"     # Add a new goal
  python agent_helper.py log [N]             # Last N lines of agent log
"""

import json
import os
import sys
import time
from pathlib import Path

REPO_DIR = Path(__file__).parent.parent
PYTHON_DIR = Path(__file__).parent
GOALS_FILE = PYTHON_DIR / "goals.json"
AGENT_LOG_DIR = PYTHON_DIR / "agent_log"
CYCLES_LOG = AGENT_LOG_DIR / "cycles.jsonl"


def cmd_game_state():
    """Query current game state from TF2."""
    from ipc_client import get_ipc
    ipc = get_ipc()
    resp = ipc.send("query_game_state")
    if resp and resp.get("status") == "ok":
        data = resp["data"]
        return {
            "year": data.get("year"),
            "money": data.get("money"),
            "speed": data.get("speed"),
            "calendar_speed": data.get("calendar_speed"),
        }
    return {"error": "Game not responding. Is TF2 running?"}


def cmd_lines():
    """Query all transport lines."""
    from ipc_client import get_ipc
    ipc = get_ipc()
    resp = ipc.send("query_lines")
    if resp and resp.get("status") == "ok":
        lines = resp.get("data", {}).get("lines", [])
        summary = []
        for line in lines:
            summary.append({
                "id": line.get("id"),
                "name": line.get("name", ""),
                "vehicle_count": line.get("vehicle_count", 0),
                "total_transported": line.get("total_transported", 0),
                "rate": line.get("rate", 0),
                "interval": line.get("interval", 0),
                "cargo": line.get("cargo", ""),
            })
        return {"lines": summary, "count": len(summary)}
    return {"error": "Failed to query lines"}


def cmd_industries():
    """Query all industries."""
    from ipc_client import get_ipc
    ipc = get_ipc()
    resp = ipc.send("query_industries")
    if resp and resp.get("status") == "ok":
        return resp["data"]
    return {"error": "Failed to query industries"}


def cmd_demands():
    """Query town demands."""
    from ipc_client import get_ipc
    ipc = get_ipc()
    resp = ipc.send("query_town_demands")
    if resp and resp.get("status") == "ok":
        return resp["data"]
    return {"error": "Failed to query town demands"}


def cmd_metrics():
    """Get metrics dashboard text."""
    from ipc_client import get_ipc
    from memory_store import MemoryStore
    from metrics import MetricsCollector
    ipc = get_ipc()
    memory = MemoryStore()
    mc = MetricsCollector(ipc, memory)
    mc.collect()
    dashboard = mc.get_dashboard()
    text = mc.get_dashboard_text()
    return {"dashboard": dashboard, "text": text}


def cmd_decisions(n=5):
    """Get last N decisions from memory."""
    from memory_store import MemoryStore
    memory = MemoryStore()
    recent = memory.get_recent(limit=n)
    return {"decisions": recent, "count": len(recent)}


def cmd_run_cycle():
    """Run one orchestrator cycle."""
    from orchestrator import Orchestrator
    orch = Orchestrator()
    result = orch.run_cycle(cycle=1)
    return result


def cmd_goals():
    """Show current goals."""
    return load_goals()


def cmd_add_goal(description):
    """Add a new goal."""
    data = load_goals()
    goals = data.get("goals", [])

    # Generate next ID
    max_id = 0
    for g in goals:
        gid = g.get("id", "")
        if gid.startswith("g"):
            try:
                max_id = max(max_id, int(gid[1:]))
            except ValueError:
                pass
    new_id = f"g{max_id + 1}"

    new_goal = {
        "id": new_id,
        "description": description,
        "status": "active",
        "priority": len(goals) + 1,
        "progress": "",
        "blocked_reason": None,
    }
    goals.append(new_goal)
    data["goals"] = goals
    save_goals(data)
    return {"added": new_goal}


def cmd_update_goal(goal_id, key, value):
    """Update a goal field."""
    data = load_goals()
    goals = data.get("goals", [])
    for g in goals:
        if g.get("id") == goal_id:
            # Handle null values
            if value.lower() == "null":
                value = None
            g[key] = value
            data["goals"] = goals
            save_goals(data)
            return {"updated": g}
    return {"error": f"Goal '{goal_id}' not found"}


def cmd_log(n=20):
    """Get last N lines of agent cycle log."""
    if not CYCLES_LOG.exists():
        return {"entries": [], "count": 0}
    entries = []
    with open(CYCLES_LOG, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    recent = entries[-n:]
    return {"entries": recent, "count": len(recent)}


def load_goals():
    """Load goals from goals.json."""
    if not GOALS_FILE.exists():
        return {"goals": []}
    try:
        with open(GOALS_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"goals": []}


def save_goals(data):
    """Save goals to goals.json atomically."""
    tmp = GOALS_FILE.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(str(tmp), str(GOALS_FILE))


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command given. Use: game-state, lines, industries, demands, metrics, decisions, run-cycle, goals, add-goal, update-goal, log"}))
        sys.exit(1)

    cmd = sys.argv[1]

    try:
        if cmd == "game-state":
            result = cmd_game_state()
        elif cmd == "lines":
            result = cmd_lines()
        elif cmd == "industries":
            result = cmd_industries()
        elif cmd == "demands":
            result = cmd_demands()
        elif cmd == "metrics":
            result = cmd_metrics()
        elif cmd == "decisions":
            n = int(sys.argv[2]) if len(sys.argv) > 2 else 5
            result = cmd_decisions(n)
        elif cmd == "run-cycle":
            result = cmd_run_cycle()
        elif cmd == "goals":
            result = cmd_goals()
        elif cmd == "add-goal":
            if len(sys.argv) < 3:
                result = {"error": "Usage: add-goal \"description\""}
            else:
                result = cmd_add_goal(sys.argv[2])
        elif cmd == "update-goal":
            if len(sys.argv) < 5:
                result = {"error": "Usage: update-goal ID KEY VALUE"}
            else:
                result = cmd_update_goal(sys.argv[2], sys.argv[3], sys.argv[4])
        elif cmd == "log":
            n = int(sys.argv[2]) if len(sys.argv) > 2 else 20
            result = cmd_log(n)
        else:
            result = {"error": f"Unknown command: {cmd}"}

        print(json.dumps(result, indent=2, default=str))

    except Exception as e:
        print(json.dumps({"error": f"{type(e).__name__}: {e}"}, default=str))
        sys.exit(1)


if __name__ == "__main__":
    main()
