# PRD 04: Operational Playbook

## Overview

This document contains hard-won operational knowledge from extensive gameplay. Every rule here was learned through failure. An LLM implementing the TF2 domination system MUST internalize these patterns to avoid repeating costly mistakes.

## Proven Build Sequences

### Recipe: 2-Stage Road Chain (FOOD or CONSTRUCTION_MATERIALS)

The simplest and most reliable money-maker. Build these FIRST.

```
Step 1: build_industry_connection(raw_producer_id, processor_id)
        Wait 15-20 seconds for game to process
        Check game logs for "Build succeeded"

Step 2: Query lines to find new line ID
        line_id = find_new_line()

Step 3: build_cargo_to_town(processor_id, town_id, cargo)
        Wait 15-20 seconds
        Check game logs for "Build succeeded"

Step 4: Query lines to find delivery line ID
        delivery_line_id = find_new_line()

Step 5: Set both lines to load_if_available
        set_line_load_mode(line_id)
        set_line_load_mode(delivery_line_id)

Step 6: Set both lines to use all terminals
        set_line_all_terminals(line_id)
        set_line_all_terminals(delivery_line_id)

Step 7: Calculate vehicle needs and scale
        For each line:
          query lines to get current interval
          needed = ceil(current_veh * current_interval / 60)
          add_vehicle_to_line(line_id) × (needed - current_veh)

Step 8: Verify final intervals are 55-65s
```

### Recipe: 3-Stage Road Chain (TOOLS)

```
Step 1: build_industry_connection(forest_id, saw_mill_id)     # LOGS
Step 2: build_industry_connection(saw_mill_id, tools_factory_id)  # PLANKS
Step 3: build_cargo_to_town(tools_factory_id, town_id, "TOOLS")  # TOOLS
Steps 4-8: Same as 2-stage (set load mode, terminals, scale vehicles)
```

### Recipe: FUEL Chain (Vanilla — 2 Stages)

```
Step 1: build_connection(oil_well_id, oil_refinery_id, cargo="CRUDE")  # CRUDE (NOT CRUDE_OIL)
Step 2: build_cargo_to_town(oil_refinery_id, town_id, "FUEL")         # FUEL
Steps 3-7: Same as above (load mode, terminals, scale vehicles)
```

**Note**: Vanilla oil refinery produces FUEL directly from CRUDE. The expanded mod has a separate fuel refinery with different recipes. Always use `build_connection` with explicit `cargo` param for feeders — `build_industry_connection` auto-detects cargo and often picks the wrong type.

### Recipe: Rail Connection (For Long Distance)

```
Step 1: build_rail_station(industry1_id, name="Station A")
        Wait 10s, check logs

Step 2: build_rail_station(industry2_id, name="Station B")
        Wait 10s, check logs

Step 3: build_rail_track(industry1_id=X, industry2_id=Y)
        Wait 30s (async! Check logs for completion)

Step 4: verify_track_connection(industry1_id=X, industry2_id=Y)
        Must return connected="true"

Step 5: Get construction entity IDs from IPC log
        Look for "Matched con1=X con2=Y"

Step 6: create_rail_line_with_vehicles(
            station_ids="con1,con2",
            cargo_type="IRON_ORE",
            wagon_type="gondola",
            num_wagons="4",
            num_vehicles="1"
        )

Step 7: Add more trains if needed
        add_vehicle_to_line(line_id, cargo_type="IRON_ORE", wagon_type="gondola")
```

## Vehicle Scaling Formula

### Target Intervals
| Route Type | Target Interval |
|-----------|----------------|
| Ore/coal feeders (to steel mills) | 30 seconds |
| All other lines | 60 seconds |

### Calculation
```
trucks_needed = ceil(current_trucks × (current_interval / target_interval))
trucks_to_add = trucks_needed - current_trucks
```

### Examples
| Current Vehicles | Current Interval | Target | Vehicles Needed | Add |
|-----------------|-----------------|--------|----------------|-----|
| 3 | 701s | 60s | ceil(3 × 701/60) = 36 | 33 |
| 2 | 775s | 60s | ceil(2 × 775/60) = 26 | 24 |
| 14 | 80s | 60s | ceil(14 × 80/60) = 19 | 5 |
| 3 | 120s | 60s | ceil(3 × 120/60) = 6 | 3 |

### Approximate Truck Counts by Distance
| Route Distance | Trucks for 60s | Trucks for 30s |
|---------------|---------------|---------------|
| 500m | 3-4 | 6-8 |
| 1km | 5-8 | 10-16 |
| 2km | 10-15 | 20-30 |
| 3km | 15-25 | 30-50 |
| 5km | 30-50 | 60-100 |
| 7km+ | 50-90+ | Consider rail instead |

## Wagon Type Rules

### Road Vehicles
**ALWAYS use tarp/universal trucks** that carry ALL CARGO types. This allows the same truck to carry different cargos if the route is later merged into a multi-stop loop.

The `add_vehicle_to_line` handler uses `preferUniversal = true` by default for road vehicles.

### Rail Wagons
Rail wagons ARE cargo-specific. Use the correct type:

| Cargo Types | Wagon Type | Model Filter |
|------------|-----------|-------------|
| IRON_ORE, COAL, SAND, SILVER_ORE, SLAG, GRAIN, STONE | Gondola | `"gondola"` |
| CRUDE, FUEL | Tanker | `"tank"` |
| FOOD, GOODS, TOOLS, MACHINES, PLANKS, CONSTRUCTION_MATERIALS | Box car | `"box"` |
| LOGS | Stake car / Flat car | `"stake"` or `"flat"` |
| MARBLE | Stake car | `"stake"` |

**CRITICAL**: Always pass explicit `cargo_type` AND `wagon_type` when adding rail vehicles. The auto-detection from line name picks WRONG wagon types.

```python
# WRONG - auto-detects "STEEL" from line name "Steel Exchange Rail"
ipc.send('add_vehicle_to_line', {'line_id': '33066'})

# CORRECT - explicit cargo and wagon type
ipc.send('add_vehicle_to_line', {
    'line_id': '33066',
    'cargo_type': 'IRON_ORE',
    'wagon_type': 'gondola'
})
```

## Line Configuration Checklist

After creating ANY new line, ALWAYS:

1. **Set load mode** to `load_if_available` (NOT full_load)
   ```python
   ipc.send('set_line_load_mode', {'line_id': line_id})
   ```

2. **Set all terminals** so vehicles use all platforms
   ```python
   ipc.send('set_line_all_terminals', {'line_id': line_id})
   ```

3. **Scale to target interval** (60s standard, 30s for ore/coal)
   ```python
   # Query current state
   lines = ipc.send('query_lines')
   line = find_line(lines, line_id)

   # Calculate and add
   needed = ceil(line.vehicle_count * line.interval / target)
   for _ in range(needed - line.vehicle_count):
       ipc.send('add_vehicle_to_line', {'line_id': line_id})
   ```

4. **Verify interval** after adding vehicles
   ```python
   lines = ipc.send('query_lines')
   line = find_line(lines, line_id)
   assert 50 <= line.interval <= 70  # For 60s target
   ```

## Critical Gotchas (Learned the Hard Way)

### IPC Gotchas

1. **`build_road` ignores industry IDs** — it picks the AI builder's optimal route. Use `build_industry_connection` for specific industry pairs.

2. **`build_rail_station` uses `params.name`**, NOT `params.station_name`. Wrong param name = silently ignored.

3. **`log()` writes to `/tmp/tf2_simple_ipc.log`**, NOT `/tmp/tf2_build_debug.log`. The build debug log is from the AI builder's `trace()` function.

4. **`add_vehicle_to_line` auto-detects cargo from line NAME** — e.g., "Steel Exchange Rail" → detects "STEEL" → buys steel wagons even if line carries iron ore. ALWAYS pass explicit `cargo_type`.

5. **All JSON values must be strings.** `{"speed": 4}` will be silently parsed wrong by Lua. Use `{"speed": "4"}`.

6. **Rail track building is ASYNC.** `build_rail_track` returns `status: "pending"`. You must poll game logs to know when it finishes (typically 10-30 seconds).

7. **Game cargo type is `CRUDE`, not `CRUDE_OIL`.** The `add_vehicle_to_line` handler had `CRUDE_OIL` in its cargo list which caused vehicle config failures. The correct game cargo type is `CRUDE`.

8. **`build_industry_connection` auto-detects cargo — OFTEN WRONG.** Use `build_connection` with explicit `cargo` param for feeders. Line names like "Farm-FoodPlant Coal" indicate the wrong cargo type was selected.

9. **`lineEntity.itemsTransported` has NO `_thisYear` field.** Use top-level cumulative cargo keys (e.g., `GRAIN=102`) or `_lastYear` as fallback. Reading `_thisYear` returns nil/0 for ALL lines.

10. **`create_line_from_stations` requires `station_ids` as a JSON array**, not individual params. E.g., `{"station_ids": ["123", "456"]}`.

11. **`delete_line` now sells ALL vehicles before deletion.** Previous behavior (keeping 1 vehicle) caused silent deletion failures.

### Station Gotchas

7. **`newConstruction.name` does NOT set the NAME component** on the resulting entity. TF2 auto-generates station names. Use industry proximity to match stations to industries, not names.

8. **Station IDs vs Construction IDs**: `query_nearby_stations` returns **construction entity IDs**, not station entity IDs. Use construction IDs for `create_rail_line_with_vehicles`.

9. **Station placement**: Road-parallel orientation with building between tracks and road. Use `util.findEdgeForIndustry(industry, 300)` to find connected road. Place station 20m from road (not 60m).

### Train Gotchas

10. **`stationLength=1000` creates a 130-part train costing $28M.** Use `stationLength=160` (default) for reasonable trains.

11. **`buildMaximumCapacityTrain` picks WRONG wagon types.** Always use manual consist: 1 loco + N wagons with explicit cargo_type and wagon_type.

12. **vehicleConfig format must match**: `loadConfig={idx}` is an ARRAY, `reversed=false` is boolean. Malformed config silently fails.

### Economic Gotchas

13. **Revenue ONLY comes from town delivery.** Feeding raw materials to processors does NOT generate net revenue. Vehicle maintenance costs EXCEED transport income on intermediate legs.

14. **Not all towns demand all products.** Query `query_town_demands` BEFORE planning any delivery route. Delivering to a town that doesn't demand the cargo wastes money.

15. **The AI builder auto-adds vehicles to your lines.** Lines 17668, 30791, 37573 all had vehicles auto-added, running up costs. Monitor vehicle counts and remove excess.

16. **Point-to-point routes = 50% deadhead.** Vehicles return empty. Multi-stop loops reduce this.

### Build Gotchas

17. **`tryBuildRoute` from `ai_builder_route_builder.lua` is the CORRECT way to build rail tracks.** Manual SimpleProposal fails because tangent geometry, terrain heights, and edge collision detection are finicky. Previous failure: `costs=0 critical=true` from incorrect tangent lengths.

18. **Use `getOutwardTangent()` to get station track direction** before calling `tryBuildRoute`. Without it, the route builder doesn't know which direction to extend the track.

19. **Expanded mod industries have no `inputCargoTypeForAiBuilder` params** in their .con files. The AI builder skips them unless you add entries to ALL 7 backup functions in `ai_builder_new_connections_evaluation.lua`.

## Anti-Patterns (DO NOT DO)

| Anti-Pattern | Why It Fails | Do This Instead |
|-------------|-------------|-----------------|
| Build raw→processor without town delivery | Loses money (no revenue) | Always complete chain to town |
| Assume town demands cargo | Delivers to town that doesn't want it | Query `query_town_demands` first |
| Use `build_road` for specific routes | Ignores your industry IDs | Use `build_industry_connection` |
| Use `build_industry_connection` for feeders | Auto-detects WRONG cargo type | Use `build_connection` with explicit `cargo` param |
| Auto-detect wagon type from line name | Gets wrong cargo wagons | Pass explicit `cargo_type` |
| Set full_load on all stops | Vehicles wait forever at empty stations | Use load_if_available |
| Build 100+ truck lines | Expensive maintenance, diminishing returns | Use rail for routes >5km |
| Spend >40% of cash on one build | Risk bankruptcy if it fails | Budget cap at 40% |
| Ignore game logs after build | Miss errors and failures | Always check stdout after commands |
| Skip terminal configuration | Vehicles queue for one platform | Set all terminals on every line |
| Scale lines with zero transport | Adds vehicles to broken lines, hemorrhages cash | Run diagnostics first — check cargo config, supply chain, connections |
| Use `CRUDE_OIL` as cargo type | Game uses `CRUDE` — vehicles get wrong config | Always use `CRUDE` for oil well output |
| Substring-match town names in line names | "Yangon Oil refinery-Guangzhou" falsely matches "Yangon" town | Split line name on dash, check town ONLY in target part |
| Scale >5 vehicles per line per pass | Cost blowouts with expensive vehicles | Cap at 5 vehicles per scaling pass, 30% cash budget |
| Trust interval formula for new lines | New lines (1-5 vehicles) have artificially high intervals | Add max 2 vehicles conservatively for new lines |

## Session Startup Checklist

Every new session, do these in order:

```python
# 1. Check game state
resp = ipc.send('query_game_state')
assert resp.data.paused == "false"  # If paused, set_speed(4)

# 2. Run DAG builder for fresh supply chain data
from subagents.dag_builder import run_dag_builder
dag = run_dag_builder()

# 3. Query all lines and check health
lines = ipc.send('query_lines')
for line in lines:
    if line.interval > 120:  # Under-capacity
        log(f"WARNING: Line {line.id} interval={line.interval}s")
    if line.vehicle_count == 0:  # Dead line
        log(f"CRITICAL: Line {line.id} has no vehicles!")

# 4. Query town demands
demands = ipc.send('query_town_demands')

# 5. Identify unserved demands
unserved = find_unserved_demands(dag, demands, lines)

# 6. Begin orchestration loop
```

## Monitoring Dashboard (What to Track)

| Metric | Query | Warning Threshold |
|--------|-------|-------------------|
| Cash | `query_game_state` → money | < $5M |
| Line count | `query_lines` → length | Should grow each session |
| Avg interval | `query_lines` → avg(interval) | > 120s means under-capacity |
| Vehicle count | `query_vehicles` → length | Growing = good (investing) |
| Town demand served | `query_town_demands` vs active lines | < 50% = lots of opportunity |
| Build errors | Game stdout | Any error = investigate immediately |
| Profit trend | Cash delta over 5 game years | Negative = URGENT |

## Era-Specific Strategy

### Early Era (1850-1880)
- Horse-drawn carriages available (slow, cheap)
- Focus on short-distance road chains (< 2km)
- 2-stage chains only (FOOD, CONSTRUCTION_MATERIALS)
- Rail becomes available mid-era (more expensive but higher capacity)
- **Rule: No carriages on routes > 500m** (too slow, unprofitable)

### Mid Era (1880-1920)
- Motorized trucks available (faster, more capacity)
- Can now handle 3-5km road routes profitably
- Rail for distances > 5km
- Begin 3-stage chains (TOOLS, FUEL)
- Town populations growing → higher demands
- This is the BUILD phase — invest aggressively

### Late Era (1920-1960)
- Modern trucks and trains
- Air transport available for long-distance passengers
- Focus on optimizing existing network
- Complete complex chains (GOODS, MACHINES)
- Hub-and-spoke patterns efficient at scale

### Modern Era (1960+)
- All transport modes available
- Very high-speed rail
- Focus on efficiency and coverage
- Passenger revenue becomes significant
- Large-scale network optimization

## Vehicle Scaling Lessons

These were learned through expensive failures:

1. **New lines (1-5 vehicles) have artificially high intervals** — DON'T trust the formula, add max 2 conservatively
2. **Vehicle costs scale with game year** — ~$100K in 1900, $600K+ in 2400s
3. **Builder must check cash before buying vehicles** or it will bankrupt the company
4. **Cap vehicles per scaling pass at 5 per line** (was 10, caused cost blowouts)
5. **Initial build target: 120s interval** (not 60s) — let chains prove profitable before scaling
6. **Vehicle budget: max 30% of cash per scaling pass**
7. **NEVER scale lines with zero transport** — lines with `total_transported == 0` and `vehicle_count >= 12` need diagnosis, not more vehicles
8. **`remove_vehicles_from_line` IPC handler** — sells vehicles from end of list, keeps at least 1

## Chain Health Grace Period

New chains need ~5 minutes for cargo to flow end-to-end: raw producer → truck → processor → truck → town. Don't flag chains as "broken" or "degraded" within 5 minutes of the decision timestamp. Applied in: `metrics._compute_delivery_trends`, `metrics._compute_chain_health`, `surveyor._validate_chain_health`.

## Game Save/Restart Behavior

- TF2 auto-saves ONLY at year boundaries
- With slow calendar speed (0.25x), year 1900 lasts very long — no auto-save triggers
- **Restarting TF2 mid-year loses ALL built lines/vehicles since the last year boundary**
- This means 3+ game-year builds can be lost in seconds
- Workaround: manually trigger save or accept the risk

## Python Environment

- Use `PYTHONUNBUFFERED=1` when running the orchestrator to see print() output in real time
- Without it, stdout is buffered and output appears only after buffer fills or process exits
- Example: `PYTHONUNBUFFERED=1 python orchestrator.py`

## Financial Rules of Thumb

| Rule | Threshold | Action |
|------|-----------|--------|
| Max spend per build | 40% of cash | Don't exceed (was 30%, too restrictive on spread-out maps) |
| Max leg distance (road) | 10km | Skip if any single leg exceeds this (was 5km) |
| Emergency reserve | 3 months operating costs | Stop building if below |
| Line ROI target | > 5% annual | Delete if below after 3 years |
| Vehicle payback | < 2 game years | Don't buy if payback longer |
| Optimal line length (road) | 1-5km | Shorter = better |
| Optimal line length (rail) | 3-15km | Sweet spot is 5-10km |
| Vehicle scaling cap | 5 per line per pass | Prevents cost blowouts |
| Vehicle cash budget | 30% of cash per scaling pass | Prevents bankruptcy |
