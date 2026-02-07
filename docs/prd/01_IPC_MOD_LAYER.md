# PRD 01: IPC & Mod Layer

## Overview

The IPC (Inter-Process Communication) layer is a Lua mod for Transport Fever 2 that exposes the game's internal state and build commands via file-based JSON exchange. A Python client writes commands to `/tmp/tf2_cmd.json` and reads responses from `/tmp/tf2_resp.json`.

## TF2 Modding Architecture

### Mod Structure
```
local_ai_builder/
├── mod.lua                          # Mod entry point (metadata)
├── res/
│   ├── config/game_script/
│   │   └── ai_builder_script.lua    # Game script (runs every tick)
│   └── scripts/
│       ├── simple_ipc.lua           # IPC handler (ALL commands)
│       ├── ai_builder_base_util.lua         # Utility functions
│       ├── ai_builder_base_param_helper.lua # Parameter helpers
│       ├── ai_builder_construction_util.lua # Station/depot building
│       ├── ai_builder_line_manager.lua      # Line/vehicle management
│       ├── ai_builder_new_connections_evaluation.lua # Route evaluation
│       ├── ai_builder_route_builder.lua     # Rail track building (tryBuildRoute)
│       └── ai_builder_vehicle_util.lua      # Vehicle purchasing
```

### Game Script Lifecycle
TF2 calls `ai_builder_script.lua` periodically. Within that script:
1. Check `/tmp/tf2_cmd.json` for pending commands
2. Parse JSON, dispatch to handler in `simple_ipc.lua`
3. Execute command using TF2's Lua API
4. Write result to `/tmp/tf2_resp.json`
5. Continue normal AI builder operations

### Lua Sandbox Constraints
- **No `os.execute()`** — cannot run external programs
- **No `io.open()` for arbitrary paths** — use `api.util` file helpers or `/tmp/` workaround
- **No `socket`** — no network access
- **No `sleep()`** — use `os.clock()` spin-wait for delays
- **Limited standard library** — `math`, `string`, `table`, `os.clock()`, `os.time()` available
- **TF2 API** — `api.cmd`, `api.type`, `api.engine`, `api.res` available

## IPC Protocol

### File Paths
| File | Purpose | Writer | Reader |
|------|---------|--------|--------|
| `/tmp/tf2_cmd.json` | Commands TO game | Python | Lua |
| `/tmp/tf2_resp.json` | Responses FROM game | Lua | Python |
| `/tmp/tf2_simple_ipc.log` | IPC debug log | Lua | Python (read-only) |
| `/tmp/tf2_build_debug.log` | Build debug log | Lua (ai_builder) | Python (read-only) |
| `/tmp/tf2_cargo_to_town_debug.log` | Cargo-to-town debug | Lua | Python (read-only) |

### Command Format
```json
{
  "id": "abc12345",
  "cmd": "build_industry_connection",
  "ts": "1704067200000",
  "params": {
    "industry1_id": "22197",
    "industry2_id": "22169"
  }
}
```

### Response Format
```json
{
  "id": "abc12345",
  "status": "ok",
  "data": {
    "industry1_id": 22197,
    "industry2_id": 22169
  }
}
```

### Error Response
```json
{
  "id": "abc12345",
  "status": "error",
  "message": "Line not found: 99999"
}
```

### CRITICAL: Value Stringification
**ALL parameter values sent to Lua MUST be strings.** TF2's JSON parser does not handle native numbers or booleans correctly.

```python
# WRONG - will cause Lua parse errors
{"year": 1855, "money": 2500000, "paused": False}

# CORRECT - all values are strings
{"year": "1855", "money": "2500000", "paused": "false"}
```

### Python IPC Client Pattern
```python
import json, os, time, uuid

CMD_FILE = "/tmp/tf2_cmd.json"
RESP_FILE = "/tmp/tf2_resp.json"

def send_ipc(command: str, params: dict = None, timeout: float = 30.0) -> dict:
    """Send command to TF2 and wait for response."""
    request_id = uuid.uuid4().hex[:8]

    # Stringify all values
    str_params = {str(k): str(v) for k, v in (params or {}).items()}

    cmd = {
        "id": request_id,
        "cmd": command,
        "ts": str(int(time.time() * 1000)),
        "params": str_params
    }

    # Clear stale response
    if os.path.exists(RESP_FILE):
        os.remove(RESP_FILE)

    # Write command atomically (tmp + rename)
    tmp = CMD_FILE + ".tmp"
    with open(tmp, 'w') as f:
        json.dump(cmd, f)
    os.rename(tmp, CMD_FILE)

    # Poll for response
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(RESP_FILE):
            try:
                with open(RESP_FILE) as f:
                    resp = json.load(f)
                if resp.get("id") == request_id:
                    os.remove(RESP_FILE)
                    return resp
            except (json.JSONDecodeError, IOError):
                pass
        time.sleep(0.1)

    return None  # Timeout
```

## Complete IPC Handler Reference

### System Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `ping` | — | Returns "pong", connectivity test |
| `pause` | — | Pauses game (speed=0) |
| `resume` | — | Resumes game (speed=4) |
| `set_speed` | `speed` (0-4) | Set game speed |
| `add_money` | `amount` (default: 50000000) | Add money to player |
| `set_calendar_speed` | `speed` (int) | Set date advancement rate (separate from game speed). Value = 2000/displayed_speed at 4x. 4=500x (default), 8000=0.25x, 0=pause |

### Query Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `query_game_state` | — | Returns year, month, day, money, speed, paused |
| `query_towns` | — | All towns with ID, name, population, position |
| `query_town_demands` | — | **CRITICAL**: All towns with actual cargo demands |
| `query_town_supply` | — | All towns with full cargo supply/limit/demand values (for metrics tracking) |
| `query_town_buildings` | `town_id` | Buildings in a specific town with cargo demands |
| `query_industries` | — | All industries with ID, name, type, position |
| `query_lines` | — | All transport lines with vehicle_count, interval, frequency, transported cargo totals |
| `query_vehicles` | — | All vehicles with ID and line assignment |
| `query_stations` | — | All stations with ID and name |
| `query_nearby_stations` | `industry_id`, `radius` (300) | Stations near an industry |
| `query_available_wagons` | `cargo_type`, `station_length` (160) | Wagon models for a cargo type |
| `query_terrain_height` | `x`, `y` | Terrain height at position (water detection) |
| `check_water_path` | `x1,y1,x2,y2`, `samples` (20) | Check if water route viable |

### Road Building Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `build_road` | `cargo` (optional) | AI Builder picks optimal route (ignores specific IDs) |
| `build_industry_connection` | `industry1_id`, `industry2_id` | **RECOMMENDED**: Builds road between specific industries using full AI evaluation |
| `build_connection` | `industry1_id`, `industry2_id`, `transport_type`, `cargo` | Direct connection bypassing AI evaluation |
| `build_cargo_to_town` | `industry_id`, `town_id`, `cargo` | **CRITICAL**: Delivers final goods to town (completes supply chain) |
| `build_town_bus` | `town_id` | Build intra-city bus network |
| `build_multistop_route` | `industry_ids` (array), `line_name`, `cargo`, `transport_mode`, `target_rate` | Multi-stop route from industry IDs |

### Rail Building Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `build_rail_station` | `industry_id`, `name`, `distance` (20) | Build rail station near industry, parallel to road |
| `build_rail_track` | `station1_name`/`station2_name` OR `industry1_id`/`industry2_id` | Build track using tryBuildRoute (handles terrain) |
| `build_specific_rail_route` | `industry1_id`, `industry2_id`, `double_track`, `expensive_mode` | Build rail route with mode options |
| `verify_track_connection` | `station1_id`/`station2_id` OR `industry1_id`/`industry2_id` | Verify rail track exists via pathfinder |
| `build_train_depot` | `station_name` | Build train depot near station |

### Water/Ship Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `build_water_connection` | — | AI Builder evaluates and builds best water route |
| `build_specific_water_route` | `industry1_id`, `industry2_id`, `cargo` | Build water route between specific industries |

### Line Management Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `create_line_from_stations` | `station_ids` (array), `name`, `transport_type` | Create line from station construction IDs |
| `create_rail_line_with_vehicles` | `station_ids` (comma-separated), `name`, `cargo_type`, `num_vehicles`, `num_wagons`, `wagon_type` | Create rail line and buy vehicles in one operation |
| `delete_line` | `line_id` | Delete a transport line |
| `merge_lines` | `line_ids` (array), `name` | Merge multiple P2P lines into one multi-stop line |
| `set_line_load_mode` | `line_id`, `mode` | Set load mode: "load_if_available", "full_load_all", "full_load_any" |
| `set_line_all_terminals` | `line_id` | Set all stops to use all available terminals |
| `optimize_line_vehicles` | `line_id` | Queue line for AI Builder optimization |

### Vehicle Management Commands

| Command | Parameters | Description |
|---------|-----------|-------------|
| `add_vehicle_to_line` | `line_id`, `count` (1), `cargo_type`, `wagon_type`, `num_wagons` (4), `vehicle_model` | Add vehicles to line (auto-detects road/rail) |
| `remove_vehicles_from_line` | `line_id`, `count` | **NEW**: Sell `count` vehicles from end of line's vehicle list (keeps at least 1) |
| `sell_vehicle` | `vehicle_id` | Sell a vehicle |
| `reassign_vehicle` | `vehicle_id`, `line_id`, `stop_index` (0) | Reassign vehicle to different line |
| `buy_small_train` | `line_id`, `num_wagons` (3), `cargo_type` | Buy small train for a rail line |

### AI Builder Control

| Command | Parameters | Description |
|---------|-----------|-------------|
| `enable_auto_build` | `trucks`, `trains`, `buses`, `ships`, `full` | Enable AI auto-build features |
| `disable_auto_build` | — | Disable ALL auto-build features |

### Supply Chain Discovery

| Command | Parameters | Description |
|---------|-----------|-------------|
| `query_supply_tree` | — | **NEW**: Builds complete recursive supply chain tree server-side. Returns all towns, demands, and supplier trees with OR/AND input groups, distances, and production data. See PRD 05 for format. |

### Strategic Planning

| Command | Parameters | Description |
|---------|-----------|-------------|
| `evaluate_supply_chains` | `budget` | Evaluate all supply chains with ROI analysis |
| `plan_build_strategy` | `budget`, `rounds` (3), `min_roi` (10) | Create multi-round build strategy |

### State Management

| Command | Parameters | Description |
|---------|-----------|-------------|
| `snapshot_state` | — | Capture game state snapshot for diff comparison |
| `diff_state` | `snapshot_id` | Compare current state to snapshot (finds added/removed/changed) |

## Key Lua APIs Used

### Entity System
```lua
-- Get component data
local comp = api.engine.getComponent(entityId, api.type.ComponentType.LINE)
local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION)

-- Station groups
local sg = api.engine.system.stationGroupSystem.getStationGroup(stationId)
local sgComp = api.engine.getComponent(sg, api.type.ComponentType.STATION_GROUP)

-- Player
local player = api.engine.util.getPlayer()
```

### Command System
```lua
-- Build commands are ASYNC - use callbacks
api.cmd.sendCommand(
    api.cmd.make.buildConstruction(proposal),
    function(res, success)
        if success then
            local entityId = res.resultEntity
        end
    end
)

-- Line management
api.cmd.make.createLine(name, color, player, lineData)
api.cmd.make.updateLine(lineId, lineData)
api.cmd.make.deleteLine(lineId)

-- Vehicle management
api.cmd.make.buyVehicle(player, depotId, vehicleConfig)
api.cmd.make.setLine(vehicleId, lineId, stopIndex)
api.cmd.make.sellVehicle(vehicleId)
```

### Type System
```lua
-- Line data
local line = api.type.Line.new()
local stop = api.type.Line.Stop.new()
stop.stationGroup = sgId
stop.station = 0      -- Station index within group
stop.terminal = 0     -- Terminal index (0-based)
stop.loadMode = api.type.enum.LineLoadMode.LOAD_IF_AVAILABLE

-- Alternative terminals (use ALL platforms)
local alt = api.type.StationTerminal.new()
alt.station = stop.station
alt.terminal = 1  -- Additional terminal index
stop.alternativeTerminals[1] = alt

-- Vehicle config
local config = {
    loadConfig = {1},  -- MUST be array
    reversed = false
}
```

### Route Building
```lua
-- The CORRECT way to build rail tracks
local routeBuilder = require "ai_builder_route_builder"
routeBuilder.tryBuildRoute(station1, station2, callback, params)
-- Handles: terrain, bridges, tunnels, gradients, collision avoidance

-- NEVER use manual SimpleProposal for rail - tangent geometry is too complex
```

## Game Log Locations

| Log | Path | Content |
|-----|------|---------|
| Game stdout | `~/Library/Application Support/Steam/userdata/46041736/1066780/local/crash_dump/stdout.txt` | All game output, errors, build traces |
| IPC log | `/tmp/tf2_simple_ipc.log` | IPC handler execution, command/response log |
| Build debug | `/tmp/tf2_build_debug.log` | AI builder trace output |
| Cargo-to-town | `/tmp/tf2_cargo_to_town_debug.log` | Town delivery evaluation trace |

## Restarting the Game

```bash
# Kill and restart TF2 (reloads all mod scripts)
scripts/restart_tf2.sh
```

The game starts **PAUSED** from save. You MUST send `set_speed` command (1-4) to begin.

## Critical Implementation Notes

1. **Atomic file writes**: Always write to `.tmp` then rename — prevents partial reads
2. **Response ID matching**: Each command gets a unique ID; match response ID before processing
3. **Async builds**: `build_rail_track` returns `status: "pending"` — poll game logs for completion
4. **Station IDs vs Construction IDs**: `query_nearby_stations` returns construction entity IDs, not station entity IDs. Use construction IDs for `create_rail_line_with_vehicles`.
5. **The AI builder is always running**: It may auto-add vehicles to your lines. Monitor line vehicle counts.
6. **`log()` writes to IPC log**: Use it for debugging IPC handlers
7. **`trace()` writes to build debug log**: Used by AI builder internals

## Transport Data Fields (query_lines)

The `lineEntity.itemsTransported` object has these fields:
- `_lastYear` (table) — cargo totals from last completed game year
- `_lastMonth` (table) — cargo totals from last completed game month
- `_sum` (number) — overall cumulative total
- **Top-level cargo keys** (e.g., `GRAIN=102`, `FOOD=46`) — cumulative totals per cargo type

**There is NO `_thisYear` field.** Using `_thisYear` will always return nil/0.

In year 1 (1900), `_lastYear` is always 0 because no year has completed yet. Use top-level cumulative cargo keys as the primary transport indicator. Fall back to `_lastYear` only if no top-level keys exist.

The `rate` field on a line entity indicates real-time vehicle throughput (vehicles moving per unit time). `rate > 0` means vehicles are moving but does NOT guarantee cargo is being carried — vehicles with wrong cargo config still show rate.

## Cargo Type Names (Game vs Common Names)

The game uses specific internal cargo names. Common mistakes:

| Wrong Name | Correct Game Name | Notes |
|-----------|------------------|-------|
| `CRUDE_OIL` | `CRUDE` | Oil wells produce `CRUDE`, not `CRUDE_OIL` |
| `OIL` | `CRUDE` (for raw) or `FUEL`/`PLASTIC` (for products) | Oil refineries consume `CRUDE` and produce `FUEL` + `PLASTIC` |
| `CONSTR_MAT` | `CONSTRUCTION_MATERIALS` | Full name required |

The `add_vehicle_to_line` handler matches cargo types from line names using longest-first substring matching to prevent false matches (e.g., `OIL_SAND` before `OIL`, `IRON_ORE` before `IRON`).

## delete_line Behavior

The `delete_line` handler automatically sells ALL vehicles on the line before deleting it. Previous behavior (keeping 1 vehicle) caused silent deletion failures.
