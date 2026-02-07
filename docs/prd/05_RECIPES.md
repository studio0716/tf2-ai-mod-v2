# PRD 05: Strategy Recipes

## Overview

This document catalogs every proven strategy ("recipe") for building profitable supply chains in Transport Fever 2. Each recipe is a named, repeatable playbook with exact IPC commands, prerequisites, and hard-won lessons. Recipes are organized by difficulty and era suitability.

**Golden rule:** Revenue ONLY comes from delivering final goods to towns. Every recipe must end at a town or feed into one that does.

---

## Recipe Catalog (Quick Reference)

| # | Recipe | Difficulty | Era | Stages | Final Cargo | Transport |
|---|--------|-----------|-----|--------|-------------|-----------|
| 1 | [Stone Loop](#recipe-1-the-stone-loop) | Starter | Any | 2 | CONSTRUCTION_MATERIALS | Road |
| 2 | [Bread & Butter](#recipe-2-bread--butter) | Starter | Any | 2 | FOOD | Road |
| 3 | [Ship Start](#recipe-3-the-ship-start) | Starter | 1850+ | 2-3 | Any | Ship |
| 4 | [River Food](#recipe-4-the-river-food-run) | Starter | 1850+ | 2 | FOOD | Ship |
| 5 | [Cattle Backhaul](#recipe-5-the-cattle-backhaul) | Starter | Any | 2 | FOOD | Road/Ship |
| 6 | [Food + ConMat Combo](#recipe-6-food--conmat-combo) | Starter | 1850+ | 2+2 | FOOD + CONMAT | Road |
| 7 | [Lumber Run](#recipe-7-the-lumber-run) | Intermediate | 1880+ | 3 | TOOLS | Road |
| 8 | [Black Gold Pipeline](#recipe-8-the-black-gold-pipeline) | Intermediate | 1880+ | 4 | FUEL | Road/Rail |
| 9 | [Rail Trunk with Truck Feeders](#recipe-9-rail-trunk-with-truck-feeders) | Intermediate | 1900+ | 2-3 | Any | Rail+Road |
| 10 | [Steel Payday](#recipe-10-the-steel-payday) | Advanced | 1880+ | 3+ | STEEL (intermediate) | Rail |
| 11 | [Dual Steel Mill Loop](#recipe-11-the-dual-steel-mill-loop) | Advanced | 1880+ | 3+ | STEEL (intermediate) | Rail/Ship |
| 12 | [Water Steel Chain](#recipe-12-the-water-steel-chain) | Advanced | 1850+ | 3+ | STEEL (intermediate) | Ship |
| 13 | [Double Oil Well Train](#recipe-13-the-double-oil-well-train) | Expert | Any | 4 | FUEL | Rail |
| 14 | [Hub Circle Network](#recipe-14-the-hub-circle-network) | Expert | 1920+ | N/A | All | Rail+Road |
| 15 | [Tropical Ship Network](#recipe-15-the-tropical-ship-network) | Expert | Any | N/A | All | Ship |

---

## Starter Recipes

### Recipe 1: The Stone Loop

**The simplest money-maker in the game.** Quarry stone has a unique 1:1 production ratio, meaning perfectly balanced loads with no waste.

```
Quarry ──[STONE]──> Construction Materials Plant ──[CONMAT]──> TOWN
```

**Prerequisites:**
- Quarry within 3km of a Construction Materials Plant
- Town that demands CONSTRUCTION_MATERIALS (verify with `query_town_demands`)
- Ideally: town sits between quarry and plant for a natural loop

**Why it works:**
- 1:1 ratio (unique among all chains) = balanced loads guaranteed
- Only 2 stages = low complexity, fast ROI
- Construction materials are always in demand

**Build Sequence:**
```
1. ipc.send('build_industry_connection', {industry1_id: QUARRY_ID, industry2_id: PLANT_ID})
   Wait 15-20s, check logs for "Build succeeded"

2. ipc.send('query_lines')  # Find the new line ID

3. ipc.send('build_industry_connection', {industry1_id: PLANT_ID, industry2_id: TOWN_ID})
   OR: ipc.send('build_cargo_to_town', {industry_id: PLANT_ID, town_id: TOWN_ID, cargo: "CONSTRUCTION_MATERIALS"})

4. ipc.send('set_line_load_mode', {line_id: LINE_ID})        # For BOTH lines
5. ipc.send('set_line_all_terminals', {line_id: LINE_ID})     # For BOTH lines
6. Scale vehicles to 60s interval (see Vehicle Scaling below)
7. Verify intervals are 55-65s
```

**Vehicle count (road):**
| Route Distance | Trucks Needed (60s) |
|---------------|-------------------|
| 500m | 3-4 |
| 1km | 5-8 |
| 2km | 10-15 |

**Profitability:** Break even in ~3-5 game years. Low risk.

**Loop variant (preferred):**
If geography allows, build as a 3-stop loop: `Quarry -> Plant -> Town -> Quarry`. Only 1/3 of the route is deadhead (empty) instead of 1/2.

---

### Recipe 2: Bread & Butter

**The FOOD chain. Reliable, high-demand, always profitable.**

```
Farm ──[GRAIN]──> Food Processing Plant ──[FOOD]──> TOWN
```

**Prerequisites:**
- Farm within 3km of a Food Processing Plant
- Town that demands FOOD (verify with `query_town_demands`)

**Why it works:**
- FOOD has the highest demand of any cargo type (often 60-80 units)
- 2 stages = simple, fast setup
- Farms are common on every map

**Build Sequence:** Same as Stone Loop (swap industry types).

**Key difference from Stone Loop:** Grain has a 2:1 production ratio (2 grain = 1 food), so you may need slightly more vehicles on the feeder leg than the delivery leg.

**Profitability:** Break even in ~3-5 game years. Moderate demand fluctuation.

---

### Recipe 3: The Ship Start

**Use ships when water access exists. Highest capacity, lowest cost, no track infrastructure.**

```
[Any water-adjacent industry] ──[SHIP]──> [Any water-adjacent processor/town]
```

**Prerequisites:**
- Industries near rivers or coastline (within 500m of water)
- `check_water_path` returns viable route

**Why it works:**
- Ships carry 90 units (Zoroaster) vs 5-10 for early trucks
- No track/road infrastructure cost (waterways are free)
- Lowest maintenance of any vehicle type
- Ships refit cargo automatically at each port

**Best candidates:**
- Oil well near river -> Oil refinery near river
- Coal mine near coast -> Steel mill near coast
- Any bulk commodity with water endpoints

**Build Sequence:**
```
1. Query industries for water access (terrain height near water)
2. Build port at source industry
3. Build port at destination industry
4. Create ship line between ports
5. Purchase 1-2 ships (high capacity covers most demand)
6. Add truck feeder lines for final-mile delivery to towns
```

**Profitability:** Fastest ROI of any transport mode. Ships print money.

**Lesson learned (Jan 2026):** On maps with water access, ALWAYS check for ship routes before defaulting to road or rail.

---

### Recipe 4: The River Food Run

**Ship-based variant of Bread & Butter for water-accessible farms.**

```
Farm [port] ──[GRAIN via ship]──> Food Processing Plant [port] ──[FOOD via truck]──> TOWN
```

**Prerequisites:**
- Farm with river/water access
- Food processing plant also on water
- Town within truck range of food plant

**Why it works:**
- 2-3 small boats handle all grain transport (replaces 10+ trucks)
- Return trips carry food (grain out, food back = same ship!)
- Add a second farm near the food plant for even better utilization

**Profitability:** Best-in-class for FOOD chains when water is available.

---

### Recipe 5: The Cattle Backhaul

**Exploit same-wagon bidirectional loading.**

```
Farm ──[LIVESTOCK]──> Food Processing Plant ──[FOOD]──> (same wagon returns)
```

**Why it works:**
- Cattle and food use the same wagon type
- With `autoLoadConfig`, wagons refit at each station
- Train/ship full in both directions = near-zero deadhead

**Best used with:** Rail or ship. Trucks benefit less from auto-refit.

---

### Recipe 6: Food + ConMat Combo

**Build BOTH easy chains to the same town for maximum growth.**

```
Farm ──[GRAIN]──> Food Plant ──[FOOD]──> TOWN <──[CONMAT]── ConMat Plant <──[STONE]── Quarry
```

**Prerequisites:**
- Town that demands BOTH FOOD and CONSTRUCTION_MATERIALS
- Farm + Food Plant within range
- Quarry + ConMat Plant within range
- All feeding the same town

**Why it works:**
- Towns need BOTH cargo types to grow
- Supplying both accelerates town population growth
- Shared town delivery infrastructure
- Only 5 industries needed total

**This is the recommended starting network for any new game.**

**Profitability:** Synergistic. Town growth increases demand for both products, creating a virtuous cycle.

---

## Intermediate Recipes

### Recipe 7: The Lumber Run

**3-stage TOOLS chain. Higher value cargo, moderate complexity.**

```
Forest ──[LOGS]──> Saw Mill ──[PLANKS]──> Tools Factory ──[TOOLS]──> TOWN
```

**Prerequisites:**
- Forest, Saw Mill, and Tools Factory within reasonable distance
- Town that demands TOOLS (verify with `query_town_demands`)

**Why it works:**
- TOOLS has 1.2x cargo value multiplier (higher than FOOD/CONMAT)
- Logs and planks use the same wagon type (stake car) = bidirectional loading on rail
- 3 stages is manageable complexity

**Build Sequence:**
```
1. ipc.send('build_industry_connection', {industry1_id: FOREST_ID, industry2_id: SAW_MILL_ID})
2. ipc.send('build_industry_connection', {industry1_id: SAW_MILL_ID, industry2_id: TOOLS_FACTORY_ID})
3. ipc.send('build_cargo_to_town', {industry_id: TOOLS_FACTORY_ID, town_id: TOWN_ID, cargo: "TOOLS"})
4. Set load mode + all terminals on ALL 3 lines
5. Scale vehicles to 60s intervals
```

**Geographic ideal:** Forest far from saw mill, with tools factory and town between them. This maximizes revenue (paid by crow-flies distance).

**Profitability:** Break even in ~5-8 game years. Worth the wait for higher-value cargo.

---

### Recipe 8: The Black Gold Pipeline

**4-stage FUEL chain. The most profitable single-chain recipe long-term.**

```
Oil Well ──[CRUDE_OIL]──> Oil Refinery ──[OIL]──> Fuel Refinery ──[FUEL]──> TOWN
```

**CRITICAL: CRUDE_OIL and OIL are DIFFERENT cargos!**
- Oil well produces CRUDE_OIL (raw)
- Oil refinery turns CRUDE_OIL into OIL (intermediate)
- Fuel refinery turns OIL into FUEL (final, delivered to town)

**Prerequisites:**
- Oil Well, Oil Refinery, and Fuel Refinery within range
- Town that demands FUEL (verify with `query_town_demands`)

**Build Sequence:**
```
1. ipc.send('build_industry_connection', {industry1_id: OIL_WELL_ID, industry2_id: OIL_REFINERY_ID})
2. ipc.send('build_industry_connection', {industry1_id: OIL_REFINERY_ID, industry2_id: FUEL_REFINERY_ID})
3. ipc.send('build_cargo_to_town', {industry_id: FUEL_REFINERY_ID, town_id: TOWN_ID, cargo: "FUEL"})
4. Set load mode + all terminals on ALL 3 lines
5. Scale vehicles (60s target for all legs)
```

**Warning:** This recipe requires patience. 4 stages means higher build cost and longer break-even (~8-10 game years). Ensure you have sufficient cash reserves before starting.

**Tank car advantage:** All stages use tank cars on rail, enabling continuous two-way loading if route geometry is right.

**Profitability:** Slow start but generates millions long-term. Patient capital required.

---

### Recipe 9: Rail Trunk with Truck Feeders

**The intermodal recipe. Use trucks for first/last mile, rail for the long haul.**

```
[Industry A] ──[TRUCK 500m]──> Rail Station A ──[TRAIN 5km+]──> Rail Station B ──[TRUCK 500m]──> [Industry B / Town]
```

**Prerequisites:**
- Two industry clusters or towns separated by 5km+
- Road connections shorter routes for trucks (<500m)

**When to use:**
- Road routes would need 30+ trucks (>3km distance)
- Two industries are far apart but have short road connections to potential station sites

**Build Sequence:**
```
1. Build rail stations near each industry cluster
2. Build rail track between stations (uses tryBuildRoute)
3. Verify track connection with verify_track_connection
4. Create rail line with appropriate wagons
5. Build truck feeder lines from industries to each rail station
6. Set load modes, scale vehicles
```

**Key insight:** The truck feeders should be SHORT (<500m). If feeder distance is >1km, consider moving the rail station closer.

---

## Advanced Recipes

### Recipe 10: The Steel Payday

**The proven rail-based steel production recipe. This is our battle-tested sequence for connecting coal and iron to steel mills via rail.**

```
Iron Ore Mine ──[TRUCK]──> Steel Mill <──[TRUCK]── Coal Mine
                              |
              (also connected via RAIL for long-distance inputs)
```

**Prerequisites:**
- Iron ore mine, coal mine, and steel mill identified
- Rail for long-distance connections (>2km)
- Truck feeders for short-distance connections (<2km)
- Steel must ultimately feed into a TOWN chain (Goods/Machines/Tools factory -> Town)

**CRITICAL: Steel is INTERMEDIATE. This recipe alone does NOT generate revenue. You MUST extend the chain to a town.**

**Proven Build Sequence:**
```
Step 1: Build feeder roads
  ipc.send('build_industry_connection', {
    industry1_id: IRON_MINE_ID,
    industry2_id: STEEL_MILL_ID
  })
  ipc.send('build_industry_connection', {
    industry1_id: COAL_MINE_ID,
    industry2_id: STEEL_MILL_ID
  })

Step 2: Build rail stations (for long-distance connections)
  ipc.send('build_rail_station', {
    industry_id: STEEL_MILL_A_ID,
    name: "Steel Mill A Station"
  })
  ipc.send('build_rail_station', {
    industry_id: STEEL_MILL_B_ID,
    name: "Steel Mill B Station"
  })

Step 3: Build rail track
  ipc.send('build_rail_track', {
    industry1_id: STEEL_MILL_A_ID,
    industry2_id: STEEL_MILL_B_ID
  })
  Wait 10-30s (ASYNC! Poll logs for completion)

Step 4: Verify connection
  ipc.send('verify_track_connection', {
    industry1_id: STEEL_MILL_A_ID,
    industry2_id: STEEL_MILL_B_ID
  })
  Must return connected="true"

Step 5: Get construction entity IDs from IPC log
  Look for "Matched con1=X con2=Y"

Step 6: Create rail line
  ipc.send('create_rail_line_with_vehicles', {
    station_ids: "CON1_ID,CON2_ID",    # Construction IDs, NOT station IDs!
    cargo_type: "IRON_ORE",
    wagon_type: "gondola",
    num_wagons: "4",
    num_vehicles: "1"
  })

Step 7: Scale truck feeders
  Add trucks until interval is 30s (ore/coal feeders target 30s, not 60s):
  - Iron ore feeder: ~7 trucks for ~80s interval
  - Coal feeder: ~10 trucks for ~84s interval
```

**Wagon types for steel chain:**
| Cargo | Wagon Type | Model Filter |
|-------|-----------|-------------|
| IRON_ORE | Gondola | `"gondola"` |
| COAL | Gondola | `"gondola"` |
| STEEL | Box car | `"box"` |

**CRITICAL gotcha:** When adding rail vehicles with `add_vehicle_to_line`, ALWAYS pass explicit `cargo_type` parameter. The auto-detection reads the line NAME and picks wrong wagons (e.g., "Steel Exchange Rail" -> detects "STEEL" -> buys steel wagons when you want iron ore gondolas).

**Extending to revenue:** Steel alone doesn't make money. Connect onward:
- Steel -> Goods Factory -> Town (needs PLASTIC too)
- Steel -> Machines Factory -> Town (needs PLANKS too)
- Steel -> Tools Factory -> Town (simplest, needs PLANKS too)

**Historical results:** Iron ore feeder at ~7 trucks, coal feeder at ~10 trucks achieves 80-84s intervals. Rail line with 4 gondola wagons handles throughput well.

---

### Recipe 11: The Dual Steel Mill Loop

**100% rail/ship utilization by cross-delivering between two steel mills. The highest-efficiency steel recipe.**

```
         IRON_ORE (truck)                    COAL (truck)
Iron Mine ──────────> Steel Mill A    Coal Mine ──────────> Steel Mill B
                          |                                     |
                          └────── RAIL/SHIP (both directions) ──┘
                         COAL eastbound ←→ IRON_ORE westbound
```

**Concept:** Each steel mill needs COAL + IRON_ORE. Instead of trucking both to each mill, truck ONE input to each mill locally and exchange the OTHER input between mills via rail/ship.

**Prerequisites:**
- Two steel mills within 3-8km of each other
- Coal mine near one steel mill
- Iron ore mine near the OTHER steel mill
- Rail or water connection possible between the two mills

**Why it works:**
- Traditional: 4 truck routes, all with empty returns = ~50% utilization
- This recipe: 2 short truck routes + 1 rail/ship route at 100% utilization (full both directions)
- 2-3x profit improvement vs traditional setup

**Selection Algorithm:**
```
1. Find all steel mills, calculate distance between pairs
2. For each mill, find closest COAL mine and closest IRON_ORE mine
3. Assign roles:
   - Mill with closer IRON_ORE gets iron trucked locally
   - Mill with closer COAL gets coal trucked locally
4. Check for water connection between mills (prefer ship if available)
5. Build:
   - Truck: Iron Mine -> Mill_A (short, local)
   - Truck: Coal Mine -> Mill_B (short, local)
   - Rail/Ship: Mill_A <-> Mill_B (COAL eastbound, IRON_ORE westbound)
```

**Route pattern:**
```
1. Train/Ship loads COAL at Mill_B area
2. Travels to Mill_A, unloads COAL
3. Loads IRON_ORE at Mill_A area
4. Travels to Mill_B, unloads IRON_ORE
5. Repeat - 100% loaded both directions!
```

**Wagon notes:** Gondola wagons carry both COAL and IRON_ORE (both are bulk cargo). With `autoLoadConfig={1}`, wagons auto-load whatever cargo is available at each station.

**Example from current save:**
- Mill A: Steel Mill at (-685, 1156) -- Iron Mine 15602 only 901m away
- Mill B: Steel Mill at (2568, -2735) -- Coal Mine 18762 only 1773m away
- Distance between mills: 5072m (ideal for rail)

**Profitability:** 2-3x vs traditional steel setup. Eliminates deadheading on the longest (most expensive) leg.

---

### Recipe 12: The Water Steel Chain

**Ship-based steel input delivery. Essential when water connects mines to steel mills.**

```
Coal Mine [PORT] ──[SHIP]──> Steel Mill [PORT]
Iron Mine [PORT] ──[SHIP]──> Steel Mill [PORT]
```

**Prerequisites:**
- Coal mine OR iron mine with water access (river/coast within 500m)
- Steel mill with water access
- Ships available (Zoroaster: 90 capacity, any cargo, 1850+)

**Why it's essential in 1850-1880:**
- Carriages CANNOT work for routes >500m (verified: bankruptcy on multiple attempts)
- 2.8km carriage route loses ~$27k/month even with 1 vehicle
- Ships are the ONLY viable bulk transport in early era for distances >500m

**Build Sequence:**
```
1. Query industries for water access
2. Identify mines near water AND steel mills near water
3. Build port at mine, build port at steel mill
4. Create ship route
5. Ships carry bulk cargo (coal, iron ore) efficiently at 90 units/trip
6. Use short carriage feeders (<500m) ONLY for industries not reachable by ship
```

**Fallback:** If no water access, must use rail. Carriages are NOT viable for steel chain distances.

---

## Expert Recipes

### Recipe 13: The Double Oil Well Train

**The highest-profit single train route in the game. Leverages fuel chain geometry for maximum utilization.**

```
Well A -> Refinery (drop crude) -> Well B -> Refinery (drop crude, pick oil) -> Fuel Plant (drop oil, pick fuel) -> Town -> Well A
```

**Prerequisites:**
- TWO oil wells within reasonable distance of each other
- One oil refinery
- One fuel refinery
- One town with FUEL demand
- All five locations roughly in a line

**Why it works:**
- Train is loaded on 4 of 6 legs (only 2 legs empty)
- Leverages 2:1 crude-to-oil ratio (two wells needed to keep refinery fed)
- All stages use tank cars = no wagon switching needed

**Geographic requirements:**
- Ideal: two oil wells near each other
- Bonus: oil industry next to river = "won the lottery, almost like cheating"
- Avoid steep gradients (loaded tank cars are heavy)

**Profitability:** Takes patience (~5 game years to become highly profitable). Generates millions long-term. This is the single best train route in TF2.

---

### Recipe 14: The Hub Circle Network

**Late-game circular rail network with regional hubs. Self-optimizing cargo distribution.**

```
        Hub A ────────── Hub B
       /    \            /    \
  Town 1   Town 2   Town 3   Town 4
      |        |        |        |
  Industry  Industry  Industry  Industry
       \                        /
        Hub D ────────── Hub C
```

**Setup:**
```
1. Build circular main rail line touching all regions of the map
2. Place hub stations at strategic points (river crossings, industry clusters)
3. Connect local industries to nearest hub via truck feeders
4. Run inter-hub trains for long-distance cargo
5. Run town-delivery trains from hubs to nearby towns (2-4 products per train)
```

**Why it works:**
- Network self-optimizes cargo routing through hubs
- New industries just need a truck feeder to the nearest hub
- Inter-hub transfers handle long-distance movement automatically
- Scales to entire map with minimal additional management

**Best used:** Mid-game onward when you have 10+ industry chains established and need to connect distant parts of the map.

---

### Recipe 15: The Tropical Ship Network

**Exploit water-heavy tropical maps for maximum ship usage.**

**Setup:**
```
1. Identify ALL water-accessible industries
2. Build port network connecting coastal/river industries
3. Use ships for bulk transport between ports
4. Minimal rail/road -- only for inland connections
```

**Advantage:** Ships have highest capacity (90+ units), lowest cost, flexible cargo type (auto-refit), and zero infrastructure cost for waterways.

**Best used:** Any tropical map or map with extensive river/coast geography.

---

## Recipe Selection Flowchart

Use this decision tree to pick the right recipe:

```
START
  |
  ├── Is it your first route?
  │     YES ──> Do you have water access?
  │               YES ──> Recipe 3: Ship Start
  │               NO  ──> Recipe 6: Food + ConMat Combo
  │
  ├── Do you have an incomplete chain? (intermediate only, no town delivery)
  │     YES ──> STOP. Extend existing chain to a town FIRST.
  │
  ├── What's the distance?
  │     < 500m ──> Skip (not worth building)
  │     500m-3km ──> Road recipes (1, 2, 6, 7, 8)
  │     3-8km ──> Rail recipes (9, 10, 11) or Ship (3, 12)
  │     8km+ ──> Rail (13, 14) or Ship (15)
  │
  ├── What era is it?
  │     1850-1880 ──> SHIP FIRST (3, 4, 12), then short road (1, 2, 6)
  │                   NEVER use carriages >500m!
  │     1880-1920 ──> Road (1-8) or Rail (9-11)
  │     1920+ ──> Hub network (14), optimize existing
  │
  └── What cargo value do you want?
        Low risk ──> FOOD or CONMAT (Recipes 1, 2, 6)
        Medium ──> TOOLS or FUEL (Recipes 7, 8)
        High risk/reward ──> GOODS or MACHINES (requires Steel recipes 10-12 first)
```

---

## Universal Post-Build Checklist

**After creating ANY new line, ALWAYS do these steps:**

```python
# 1. Set load mode to load_if_available (NOT full_load)
ipc.send('set_line_load_mode', {'line_id': line_id})

# 2. Set all terminals so vehicles use all platforms
ipc.send('set_line_all_terminals', {'line_id': line_id})

# 3. Query and scale to target interval
lines = ipc.send('query_lines')
line = find_line(lines, line_id)
target = 30 if is_ore_coal_feeder else 60
needed = ceil(line.vehicle_count * line.interval / target)
for _ in range(needed - line.vehicle_count):
    ipc.send('add_vehicle_to_line', {'line_id': line_id})

# 4. Verify interval
lines = ipc.send('query_lines')
line = find_line(lines, line_id)
assert (target - 10) <= line.interval <= (target + 10)
```

## Vehicle Scaling Formula

```
trucks_needed = ceil(current_trucks * (current_interval / target_interval))
trucks_to_add = trucks_needed - current_trucks
```

**Target intervals:**
| Route Type | Target |
|-----------|--------|
| Ore/coal feeders (to steel mills) | 30 seconds |
| All other lines | 60 seconds |

**Approximate truck counts by distance:**
| Distance | Trucks (60s target) | Trucks (30s target) |
|----------|-------------------|-------------------|
| 500m | 3-4 | 6-8 |
| 1km | 5-8 | 10-16 |
| 2km | 10-15 | 20-30 |
| 3km | 15-25 | 30-50 |
| 5km+ | 30-50+ | Consider rail instead |

---

## Wagon Type Reference

### Road Vehicles
**ALWAYS use ALL CARGO / tarp / universal trucks.** This allows the same truck to carry different cargos on multi-stop loops.

### Rail Wagons
Rail wagons are cargo-specific. Match correctly:

| Cargo Types | Wagon Type | Model Filter |
|------------|-----------|-------------|
| IRON_ORE, COAL, SAND, SILVER_ORE, SLAG, GRAIN, STONE | Gondola | `"gondola"` |
| OIL, CRUDE_OIL, FUEL | Tanker | `"tank"` |
| FOOD, GOODS, TOOLS, MACHINES, PLANKS, CONSTRUCTION_MATERIALS | Box car | `"box"` |
| LOGS | Stake car / Flat car | `"stake"` or `"flat"` |
| MARBLE | Stake car | `"stake"` |

**CRITICAL:** Always pass explicit `cargo_type` AND `wagon_type` when adding rail vehicles:
```python
# WRONG - auto-detects from line name, gets wrong wagon
ipc.send('add_vehicle_to_line', {'line_id': '33066'})

# CORRECT
ipc.send('add_vehicle_to_line', {
    'line_id': '33066',
    'cargo_type': 'IRON_ORE',
    'wagon_type': 'gondola'
})
```

---

## Expanded Industry Mod Recipes

Workshop mod 1950013035 changes recipes significantly. **ALWAYS check `industry.type`** to determine standard vs advanced.

### Mod-Specific Chain Variants

| Standard Recipe | Mod Variant | Key Difference |
|----------------|-------------|----------------|
| OIL -> PLASTIC (Chemical plant) | GRAIN -> PLASTIC (Advanced chemical plant) | No oil needed! |
| GRAIN -> FOOD (Food plant) | MEAT/COFFEE/ALCOHOL -> FOOD (Advanced food plant) | Different raw inputs |
| PLANKS + STEEL -> TOOLS (Tools factory) | STEEL -> TOOLS (Advanced tools factory) | No planks needed! |
| STEEL + PLASTIC -> GOODS (Goods factory) | PLASTIC + PLANKS/PAPER/SILVER -> GOODS (Advanced goods factory) | No steel needed! |
| PLANKS + STEEL -> MACHINES (Machines factory) | SILVER + STEEL -> MACHINES (Advanced machines factory) | Silver replaces planks |

**Impact on recipes:**
- Advanced tools factory simplifies Recipe 7 (no saw mill needed, just steel -> tools -> town)
- Advanced chemical plant creates an alternative PLASTIC source from grain (no oil chain needed)
- Advanced food plant requires meat/coffee/alcohol processors upstream instead of farms

---

## Anti-Patterns (Failed Recipes)

These strategies have been tried and FAILED. Historical data from `patterns.json`:

### Intermediate-Only Rail Lines
**Every single intermediate cargo rail line has negative ROI:**
- COAL rail: 0 successes, 4 failures, avg ROI -103%
- GRAIN rail: 0 successes, 6 failures, avg ROI -101%
- STONE rail: 0 successes, 4 failures, avg ROI -109%
- IRON_ORE rail: 0 successes, 1 failure, avg ROI -108%
- STEEL rail: 0 successes, 3 failures, avg ROI -113%

**Lesson:** Rail lines carrying intermediate cargo (not final goods) BLEED MONEY unless they're part of a complete chain to a town.

### Carriage Routes >500m (1850-1880)
- 2.8km carriage route loses ~$27k/month even with 1 vehicle
- Construction chain (Quarry->Plant 2878m + Plant->Town 934m) NOT profitable with carriages
- Even complete chains to towns fail if using carriages on long routes

**Lesson:** In 1850-1880, use ships or rail for anything >500m. Carriages are last resort for very short feeders only.

### Point-to-Point Lines
- Any 2-stop line (A->B->A) has 50% deadhead
- Multiple isolated P2P routes multiply losses
- Company heading for bankruptcy if you see multiple P2P lines

**Lesson:** ALWAYS build multi-stop loops (3+ stops) or extend into complete chains ending at towns.

### Over-Vehicled Lines
- 10+ trucks on early-game lines = massive losses
- Trucks have high maintenance relative to capacity
- More vehicles = more congestion = diminishing returns

**Lesson:** Start with calculated amount, verify interval, add incrementally. Never bulk-add.

---

## Financial Guard Rails

| Rule | Threshold | Action |
|------|-----------|--------|
| Max spend per build | 30% of cash | Don't exceed |
| Emergency reserve | 3 months operating costs | Stop building if below |
| Line ROI target | >5% annual | Delete if below after 3 years |
| Vehicle payback | <2 game years | Don't buy if payback longer |
| Optimal road length | 1-5km | Shorter = better |
| Optimal rail length | 3-15km | Sweet spot is 5-10km |

---

## Era-Specific Recipe Priority

### 1850-1880 (Early)
1. **Recipe 3: Ship Start** (if water available)
2. **Recipe 6: Food + ConMat Combo** (road, <2km only)
3. **Recipe 12: Water Steel Chain** (if steel mills have water access)
4. NEVER use carriages >500m

### 1880-1920 (Mid)
1. **Recipe 6: Food + ConMat Combo** (with motorized trucks, up to 5km)
2. **Recipe 7: Lumber Run** (TOOLS chain)
3. **Recipe 8: Black Gold Pipeline** (FUEL chain)
4. **Recipe 10: Steel Payday** (begin steel infrastructure)
5. **Recipe 9: Rail Trunk** (for 5km+ routes)

### 1920-1960 (Late)
1. Complete all intermediate chains to towns
2. **Recipe 11: Dual Steel Mill Loop** (optimize steel)
3. **Recipe 13: Double Oil Well Train** (optimize fuel)
4. **Recipe 14: Hub Circle Network** (scale to full map)

### 1960+ (Modern)
1. **Recipe 14: Hub Circle Network** (mature network)
2. Passenger integration for town growth
3. Network optimization and efficiency tuning
