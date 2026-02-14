#!/usr/bin/env python3
"""
TF2 AI Agent Service - Persistent autonomous agent with chat interface.

Runs three async components in one process:
  1. Work Loop  - Calls `claude -p` to autonomously manage the game
  2. Chat Server - WebSocket + HTTP on port 8080 for interactive conversation
  3. State Mgmt  - Heartbeat, goals, logging

Usage:
  python agent_service.py [--port 8080] [--cycle-delay 90] [--max-turns 10]

Requires:
  - `claude` CLI (Claude Max subscription)
  - `aiohttp` (pip install aiohttp)
"""

import asyncio
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path
from typing import Optional

import aiohttp
from aiohttp import web

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PYTHON_DIR = Path(__file__).parent
REPO_DIR = PYTHON_DIR.parent
GOALS_FILE = PYTHON_DIR / "goals.json"
AGENT_LOG_DIR = PYTHON_DIR / "agent_log"
CYCLES_LOG = AGENT_LOG_DIR / "cycles.jsonl"
HEARTBEAT_FILE = Path("/tmp/tf2_agent_heartbeat")
STATIC_DIR = PYTHON_DIR / "static"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_PORT = 8080
DEFAULT_CYCLE_DELAY = 90
DEFAULT_MAX_TURNS = 10
DEFAULT_TIMEOUT = 300  # 5 min hard cap per cycle
MAX_LOG_LINES = 500

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("agent_service")

# ---------------------------------------------------------------------------
# System Prompts
# ---------------------------------------------------------------------------
AUTONOMOUS_SYSTEM_PROMPT = """You are an autonomous AI agent managing a Transport Fever 2 game.
You run shell commands via `python agent_helper.py <command>` to query game state and take actions.

Available commands:
  python agent_helper.py game-state
  python agent_helper.py lines
  python agent_helper.py industries
  python agent_helper.py demands
  python agent_helper.py metrics
  python agent_helper.py decisions 5
  python agent_helper.py run-cycle
  python agent_helper.py goals
  python agent_helper.py update-goal <id> status <value>
  python agent_helper.py update-goal <id> progress <value>
  python agent_helper.py add-goal "description"
  python agent_helper.py log 5

Your job each cycle:
1. Check game state and metrics
2. Review current goals and progress
3. Decide whether to run an orchestrator cycle or adjust strategy
4. Take action
5. Update goal progress

Rules:
- NEVER ask questions. Decide and act.
- Always run at least one command per cycle.
- If a goal seems stuck, mark it blocked and focus on another.
- Keep your final summary to 2-3 sentences."""

CHAT_SYSTEM_PROMPT = """You are an AI assistant managing a Transport Fever 2 game.
The user is checking in to see progress or give new direction.
You have access to the same tools as the autonomous agent via `python agent_helper.py <command>`.

Available commands:
  python agent_helper.py game-state
  python agent_helper.py lines
  python agent_helper.py metrics
  python agent_helper.py decisions 5
  python agent_helper.py run-cycle
  python agent_helper.py goals
  python agent_helper.py update-goal <id> <key> <value>
  python agent_helper.py add-goal "description"
  python agent_helper.py log 10

Be conversational, concise, and helpful.
If the user sets a new goal, use `python agent_helper.py add-goal "description"`.
Show recent progress when the user first connects."""


# ---------------------------------------------------------------------------
# Shared State
# ---------------------------------------------------------------------------
chat_active = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def load_goals() -> dict:
    if not GOALS_FILE.exists():
        return {"goals": []}
    try:
        with open(GOALS_FILE, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"goals": []}


def write_heartbeat():
    try:
        HEARTBEAT_FILE.write_text(str(int(time.time())))
    except OSError as e:
        log.warning("Failed to write heartbeat: %s", e)


def log_cycle_result(result: dict):
    AGENT_LOG_DIR.mkdir(parents=True, exist_ok=True)
    entry = {
        "timestamp": time.time(),
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "result_summary": _truncate(str(result), 500),
    }
    try:
        with open(CYCLES_LOG, "a") as f:
            f.write(json.dumps(entry, default=str) + "\n")
        _trim_log(CYCLES_LOG, MAX_LOG_LINES)
    except OSError as e:
        log.warning("Failed to write cycle log: %s", e)


def _trim_log(path: Path, max_lines: int):
    """Keep only the last max_lines in a file."""
    try:
        lines = path.read_text().splitlines()
        if len(lines) > max_lines:
            path.write_text("\n".join(lines[-max_lines:]) + "\n")
    except OSError:
        pass


def _truncate(s: str, max_len: int) -> str:
    return s[:max_len] + "..." if len(s) > max_len else s


def get_state_summary() -> str:
    """Build a quick summary of game state for the work prompt."""
    parts = []

    # Goals
    goals = load_goals()
    active = [g for g in goals.get("goals", []) if g.get("status") == "active"]
    if active:
        parts.append("Active goals:")
        for g in active:
            progress = g.get("progress", "") or "no progress noted"
            parts.append(f"  [{g['id']}] {g['description']} ({progress})")
    else:
        parts.append("No active goals.")

    # Recent cycle results
    if CYCLES_LOG.exists():
        try:
            lines = CYCLES_LOG.read_text().splitlines()
            recent = lines[-5:]
            if recent:
                parts.append("\nRecent cycle results:")
                for line in recent:
                    try:
                        entry = json.loads(line)
                        parts.append(f"  {entry.get('time', '?')}: {entry.get('result_summary', '?')}")
                    except json.JSONDecodeError:
                        pass
        except OSError:
            pass

    return "\n".join(parts)


def build_work_prompt(goals: dict, state: str) -> str:
    """Build the prompt for an autonomous work cycle."""
    return f"""Current state:
{state}

Review the current game state, check metrics, and take action toward your goals.
If the game is not responding, note it and skip this cycle."""


def build_chat_context() -> str:
    """Build context string for chat interactions."""
    parts = []

    # Goals
    goals = load_goals()
    if goals.get("goals"):
        parts.append("Current goals:")
        for g in goals["goals"]:
            status = g.get("status", "?")
            progress = g.get("progress", "") or "none"
            parts.append(f"  [{g['id']}] ({status}) {g['description']} - progress: {progress}")

    # Recent agent activity
    if CYCLES_LOG.exists():
        try:
            lines = CYCLES_LOG.read_text().splitlines()
            recent = lines[-5:]
            if recent:
                parts.append("\nRecent agent activity:")
                for line in recent:
                    try:
                        entry = json.loads(line)
                        parts.append(f"  {entry.get('time', '?')}: {entry.get('result_summary', '?')}")
                    except json.JSONDecodeError:
                        pass
        except OSError:
            pass

    return "\n".join(parts) if parts else "No recent activity."


# ---------------------------------------------------------------------------
# Claude CLI Subprocess
# ---------------------------------------------------------------------------
async def run_claude(
    prompt: str,
    system_prompt: str,
    max_turns: int = 10,
    timeout: int = 300,
) -> dict:
    """Run claude -p as subprocess, return parsed result."""
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "json",
        "--max-turns", str(max_turns),
        "--system-prompt", system_prompt,
        "--allowedTools", "Bash(command)",
        "--cwd", str(PYTHON_DIR),
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            log.warning("Claude subprocess timed out after %ds, killing", timeout)
            proc.kill()
            await proc.wait()
            return {"error": "timeout", "timeout_seconds": timeout}

        if proc.returncode != 0:
            err_text = stderr.decode(errors="replace").strip()
            log.warning("Claude exited with code %d: %s", proc.returncode, err_text[:200])
            return {"error": f"exit_code_{proc.returncode}", "stderr": err_text[:500]}

        raw = stdout.decode(errors="replace").strip()
        if not raw:
            return {"error": "empty_response"}

        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            # Claude may return non-JSON text
            return {"result": raw[:2000]}

    except FileNotFoundError:
        return {"error": "claude CLI not found. Is it installed and on PATH?"}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


async def stream_claude(
    prompt: str,
    system_prompt: str,
    ws: web.WebSocketResponse,
    max_turns: int = 5,
    timeout: int = 120,
):
    """Run claude -p with streaming, send tokens over WebSocket."""
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "stream-json",
        "--max-turns", str(max_turns),
        "--system-prompt", system_prompt,
        "--allowedTools", "Bash(command)",
        "--cwd", str(PYTHON_DIR),
    ]

    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        async def read_stream():
            assert proc.stdout is not None
            async for raw_line in proc.stdout:
                line = raw_line.decode(errors="replace").strip()
                if not line:
                    continue
                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Extract text content from stream-json events
                chunk_type = chunk.get("type", "")
                if chunk_type == "assistant":
                    # Full assistant message
                    content = chunk.get("content", "")
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                await ws.send_json({"type": "token", "text": block["text"]})
                    elif isinstance(content, str) and content:
                        await ws.send_json({"type": "token", "text": content})
                elif chunk_type == "content_block_delta":
                    delta = chunk.get("delta", {})
                    text = delta.get("text", "")
                    if text:
                        await ws.send_json({"type": "token", "text": text})
                elif chunk_type == "result":
                    # Final result
                    text = chunk.get("result", "")
                    if text:
                        await ws.send_json({"type": "token", "text": text})

        try:
            await asyncio.wait_for(read_stream(), timeout=timeout)
        except asyncio.TimeoutError:
            log.warning("Chat stream timed out after %ds", timeout)
            await ws.send_json({"type": "error", "text": "Response timed out."})

    except FileNotFoundError:
        await ws.send_json({"type": "error", "text": "claude CLI not found."})
    except Exception as e:
        log.exception("stream_claude error")
        try:
            await ws.send_json({"type": "error", "text": f"Error: {e}"})
        except Exception:
            pass
    finally:
        if proc and proc.returncode is None:
            proc.kill()
            await proc.wait()
        await ws.send_json({"type": "done"})


# ---------------------------------------------------------------------------
# Work Loop
# ---------------------------------------------------------------------------
async def work_loop(cycle_delay: int, max_turns: int, timeout: int):
    """Autonomous work loop - runs claude -p each cycle."""
    global chat_active
    log.info("Work loop started (delay=%ds, max_turns=%d, timeout=%ds)",
             cycle_delay, max_turns, timeout)

    # Initial delay to let chat server start
    await asyncio.sleep(5)

    cycle = 0
    while True:
        # Pause while user is chatting
        if chat_active:
            await asyncio.sleep(5)
            continue

        cycle += 1
        log.info("=== Work cycle %d starting ===", cycle)

        goals = load_goals()
        state = get_state_summary()
        prompt = build_work_prompt(goals, state)

        result = await run_claude(
            prompt=prompt,
            system_prompt=AUTONOMOUS_SYSTEM_PROMPT,
            max_turns=max_turns,
            timeout=timeout,
        )

        log.info("Cycle %d result: %s", cycle, _truncate(str(result), 200))
        log_cycle_result(result)
        write_heartbeat()

        await asyncio.sleep(cycle_delay)


# ---------------------------------------------------------------------------
# Chat Server
# ---------------------------------------------------------------------------
async def handle_index(request: web.Request) -> web.Response:
    """Serve the chat HTML page."""
    html_path = STATIC_DIR / "chat.html"
    if html_path.exists():
        return web.FileResponse(html_path)
    return web.Response(text="chat.html not found", status=404)


async def handle_health(request: web.Request) -> web.Response:
    """Health check endpoint."""
    heartbeat = None
    if HEARTBEAT_FILE.exists():
        try:
            heartbeat = int(HEARTBEAT_FILE.read_text().strip())
        except (ValueError, OSError):
            pass

    return web.json_response({
        "status": "ok",
        "chat_active": chat_active,
        "heartbeat": heartbeat,
        "goals": load_goals(),
    })


async def handle_websocket(request: web.Request) -> web.WebSocketResponse:
    """WebSocket endpoint for chat."""
    global chat_active

    ws = web.WebSocketResponse()
    await ws.prepare(request)
    log.info("WebSocket client connected")

    # Send recent context on connect
    context_summary = build_chat_context()
    await ws.send_json({
        "type": "context",
        "text": context_summary,
    })

    try:
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                user_message = msg.data.strip()
                if not user_message:
                    continue

                log.info("Chat message: %s", _truncate(user_message, 100))
                chat_active = True

                try:
                    context = build_chat_context()
                    prompt = f"{context}\n\nUser: {user_message}"
                    await stream_claude(
                        prompt=prompt,
                        system_prompt=CHAT_SYSTEM_PROMPT,
                        ws=ws,
                        max_turns=5,
                        timeout=120,
                    )
                finally:
                    chat_active = False

            elif msg.type == aiohttp.WSMsgType.ERROR:
                log.warning("WebSocket error: %s", ws.exception())
                break
    finally:
        chat_active = False
        log.info("WebSocket client disconnected")

    return ws


def create_app() -> web.Application:
    """Create the aiohttp web application."""
    app = web.Application()
    app.router.add_get("/", handle_index)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/ws", handle_websocket)
    # Serve static files
    if STATIC_DIR.exists():
        app.router.add_static("/static/", STATIC_DIR)
    return app


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
async def run_service(port: int, cycle_delay: int, max_turns: int, timeout: int):
    """Run both the work loop and chat server concurrently."""
    app = create_app()
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    log.info("Chat server listening on http://0.0.0.0:%d", port)

    # Write initial heartbeat
    write_heartbeat()

    # Ensure log directory exists
    AGENT_LOG_DIR.mkdir(parents=True, exist_ok=True)

    try:
        await work_loop(cycle_delay, max_turns, timeout)
    except asyncio.CancelledError:
        log.info("Service shutting down...")
    finally:
        await runner.cleanup()


def main():
    import argparse
    parser = argparse.ArgumentParser(description="TF2 AI Agent Service")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"Chat server port (default: {DEFAULT_PORT})")
    parser.add_argument("--cycle-delay", type=int, default=DEFAULT_CYCLE_DELAY,
                        help=f"Seconds between work cycles (default: {DEFAULT_CYCLE_DELAY})")
    parser.add_argument("--max-turns", type=int, default=DEFAULT_MAX_TURNS,
                        help=f"Max claude turns per cycle (default: {DEFAULT_MAX_TURNS})")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                        help=f"Subprocess timeout seconds (default: {DEFAULT_TIMEOUT})")
    args = parser.parse_args()

    # Handle graceful shutdown
    loop = asyncio.new_event_loop()

    def shutdown_handler(sig, frame):
        log.info("Received signal %s, shutting down...", sig)
        for task in asyncio.all_tasks(loop):
            task.cancel()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    try:
        loop.run_until_complete(
            run_service(args.port, args.cycle_delay, args.max_turns, args.timeout)
        )
    except KeyboardInterrupt:
        log.info("Interrupted, shutting down...")
    finally:
        loop.close()


if __name__ == "__main__":
    main()
