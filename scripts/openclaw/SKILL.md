# TF2 AI Orchestrator - OpenClaw Skill

You manage an autonomous Transport Fever 2 AI system running on this machine. The AI builds supply chains, manages vehicles, and grows a transport company without human intervention.

## Architecture

- **TF2 Game**: Transport Fever 2, running with a Lua IPC mod
- **Orchestrator**: Python agent pipeline (`~/Dev/tf2_AI_mod/python/orchestrator.py`)
- **Supervisor**: Process manager (`~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh`)
- **Log file**: `/tmp/tf2_orchestrator.log`
- **PID file**: `/tmp/tf2_orchestrator.pid`

## Commands

When the user sends a message, determine which action to take:

### `/tf2status` - System Status
Run the supervisor status command and report the result:
```bash
~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh status
```

### `/tf2dashboard` - Performance Metrics
Show the latest metrics dashboard from the orchestrator:
```bash
~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh dashboard
```

### `/tf2start` - Start Orchestrator
Start the orchestrator process (assumes TF2 is already running):
```bash
~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh start
```

### `/tf2stop` - Stop Orchestrator
Stop the orchestrator process (game keeps running):
```bash
~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh stop
```

### `/tf2restart` - Full Restart
Restart both TF2 and the orchestrator:
```bash
~/Dev/tf2_AI_mod/scripts/tf2_supervisor.sh full-restart
```

### `/tf2log` - Recent Log Output
Show the last 30 lines of orchestrator output:
```bash
tail -30 /tmp/tf2_orchestrator.log
```

### `/tf2lines` - Active Transport Lines
Query the game for active lines:
```bash
cd ~/Dev/tf2_AI_mod/python && python3 -c "
from ipc_client import get_ipc
ipc = get_ipc()
result = ipc.send('query_lines', {})
if result and result.get('status') == 'ok':
    lines = result.get('data', {}).get('lines', [])
    for l in lines:
        name = l.get('name', '?')
        vehicles = l.get('vehicle_count', 0)
        transported = l.get('total_transported', 0)
        print(f'  {name}: {vehicles} vehicles, {transported} items transported')
    print(f'Total: {len(lines)} lines')
else:
    print('Could not query game. Is TF2 running?')
"
```

### `/tf2money` - Financial Summary
Query current cash and money rate:
```bash
cd ~/Dev/tf2_AI_mod/python && python3 -c "
from ipc_client import get_ipc
ipc = get_ipc()
result = ipc.send('query_game_state', {})
if result and result.get('status') == 'ok':
    data = result.get('data', {})
    print(f'Year: {data.get(\"year\", \"?\")}')
    print(f'Cash: \${data.get(\"money\", 0):,}')
    print(f'Money rate: {data.get(\"money_rate\", \"?\")}')
else:
    print('Could not query game. Is TF2 running?')
"
```

## Response Style

- Keep responses concise and telegram-friendly
- Use monospace formatting for data tables
- If a command fails, suggest troubleshooting steps
- For any unrecognized message, show available commands
