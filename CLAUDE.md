# TF2 AI Mod - LLM-Controlled Transport Fever 2

## What This Is

A Transport Fever 2 mod with a file-based IPC layer that allows an LLM (or any external program) to query game state and issue build commands. The goal is to build a multi-agent AI system that autonomously plays the game.

## Read the PRDs First

Start here — these contain everything you need to know:

| Document | What It Covers |
|----------|---------------|
| `docs/prd/00_MASTER_PRD.md` | System overview, architecture, success metrics |
| `docs/prd/01_IPC_MOD_LAYER.md` | IPC protocol, all 46 command handlers, Lua API reference |
| `docs/prd/02_GAME_DOMAIN_DAG.md` | Industries, cargos, supply chains, DAG algorithm |
| `docs/prd/03_MULTI_AGENT_SYSTEM.md` | Agent roles, orchestration loop, memory/learning |
| `docs/prd/04_OPERATIONAL_PLAYBOOK.md` | Proven recipes, scaling formulas, critical gotchas |

## Quick Start

### 1. Install the mod
```bash
./scripts/install_mod.sh

# Or manually create the symlink:
ln -s ~/Dev/tf2_AI_mod \
  ~/Library/Application\ Support/Steam/steamapps/common/Transport\ Fever\ 2/mods/AI_Optimizer_1
```
The mod must appear as a folder named `AI_Optimizer_1` inside TF2's `mods/` directory.
Verify with: `ls -la ~/Library/Application\ Support/Steam/steamapps/common/Transport\ Fever\ 2/mods/`

### 2. Start TF2
```bash
./scripts/restart_tf2.sh
```

### 3. Test IPC connection
```bash
cd python
python ipc_client.py
# Should print: Connected! Year: XXXX, Money: $X,XXX,XXX
```

### 4. Build the supply chain DAG
```bash
python dag_builder.py
# Prints: industry classification, edges, scored chains, town demands
```

### 5. The game starts PAUSED. Unpause it:
```python
from ipc_client import get_ipc
ipc = get_ipc()
ipc.send('set_speed', {'speed': '4'})
```

## Project Structure

```
tf2_AI_mod/
├── mod.lua                              # TF2 mod entry point
├── CLAUDE.md                            # This file
├── docs/prd/                            # Product Requirements Documents
│   ├── 00_MASTER_PRD.md
│   ├── 01_IPC_MOD_LAYER.md
│   ├── 02_GAME_DOMAIN_DAG.md
│   ├── 03_MULTI_AGENT_SYSTEM.md
│   └── 04_OPERATIONAL_PLAYBOOK.md
├── res/                                 # TF2 Lua mod files
│   ├── config/
│   │   ├── game_script/ai_builder_script.lua    # Main game script
│   │   ├── style_sheet/                          # UI styles
│   │   └── construction_repository/              # Industry patches
│   └── scripts/
│       ├── simple_ipc.lua                        # IPC command handlers (46 commands)
│       ├── json.lua                              # JSON parser for Lua
│       ├── ai_builder_base_util.lua              # Core utilities
│       ├── ai_builder_line_manager.lua           # Line/vehicle management
│       ├── ai_builder_new_connections_evaluation.lua  # Route evaluation
│       ├── ai_builder_route_builder.lua          # Rail track building
│       ├── ai_builder_construction_util.lua      # Station building
│       ├── ai_builder_vehicle_util.lua           # Vehicle purchasing
│       └── ... (other AI builder modules)
├── python/                              # Python IPC client & tools
│   ├── ipc_client.py                    # IPC client (send commands, query state)
│   └── dag_builder.py                   # Supply chain DAG builder
└── scripts/
    ├── restart_tf2.sh                   # Kill and restart TF2
    └── install_mod.sh                   # Install mod to TF2 directory
```

## IPC Protocol (Summary)

Commands are exchanged via JSON files:
- **Write command**: `/tmp/tf2_cmd.json`
- **Read response**: `/tmp/tf2_resp.json`

**ALL values must be strings** (Lua JSON parser requirement):
```python
# CORRECT
ipc.send('set_speed', {'speed': '4'})

# WRONG - will cause Lua parse errors
ipc.send('set_speed', {'speed': 4})
```

See `docs/prd/01_IPC_MOD_LAYER.md` for the complete handler reference.

## Critical Rules

1. **Revenue ONLY comes from delivering final goods to towns** — intermediate transport loses money
2. **Query town demands before building** — not all towns want all products
3. **Always set load_if_available** on new lines (not full_load)
4. **Always set_line_all_terminals** so vehicles use all platforms
5. **Scale lines to 60s interval** (30s for ore/coal feeders)
6. **Use explicit cargo_type for rail wagons** — auto-detection picks wrong types
7. **Check game logs after every build command** for errors

## Game Logs

| Log | Path |
|-----|------|
| Game stdout | `~/Library/Application Support/Steam/userdata/46041736/1066780/local/crash_dump/stdout.txt` |
| IPC log | `/tmp/tf2_simple_ipc.log` |
| Build debug | `/tmp/tf2_build_debug.log` |

## Your Mission

Build a multi-agent system that:
1. Observes the game state via IPC queries
2. Models the economy as a DAG (use `dag_builder.py` as starting point)
3. Plans supply chain construction (work backward from town demands)
4. Executes builds via IPC commands
5. Verifies builds succeeded (check logs, diff state)
6. Learns from outcomes (record what worked/failed)
7. Loops continuously to grow the transport empire

See `docs/prd/03_MULTI_AGENT_SYSTEM.md` for the complete agent architecture.
