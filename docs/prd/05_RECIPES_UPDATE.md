# PRD 05: RECIPES - UPDATE GUIDE

## Overview

This document specifies updates to PRD 05_RECIPES.md based on video strategy insights from KatherineOfSky and Hushey. Three areas of updates:

1. **New Recipe 16:** The Triangle Ship Loop (Video 1 concept)
2. **New Recipe 17:** Multi-Stop Train Line (Video 2 concept)
3. **Recipe 14 Redesign:** Hub Circle Network (Video 3 completely changes this recipe)
4. **Recipe Selection Flowchart:** Enhanced with video guidance
5. **Anti-Patterns section:** New anti-patterns from Video 3

---

## NEW RECIPE 16: The Triangle Ship Loop

### Insert after Recipe 15 in Recipe Catalog

**Add to Quick Reference Table:**

```
| 16 | [Triangle Ship Loop](#recipe-16-the-triangle-ship-loop) | Starter | 1850+ | 3 | FOOD/GRAIN/Any | Ship |
```

### Full Recipe Entry

---

### Recipe 16: The Triangle Ship Loop

**The Video 1 recommended early-game starter for water-accessible maps. A three-stop ship loop that generates profit with ONE ship and requires NO truck intermediate lines if geography permits.**

```
Farm [dock] ──[GRAIN via ship]──> Food Plant [dock] ──[FOOD via ship]──> Town [dock] ──[ship returns empty]──> Farm
```

**Prerequisites:**
- Farm with water access (river/coast within 100m)
- Food Processing Plant also with water access
- Town dock reachable from food plant
- All three locations roughly form a triangle (not in straight line)
- Check water connectivity before committing: `check_water_path(farm_dock, food_plant_dock)` and `check_water_path(food_plant_dock, town_dock)`

**Why it works:**
- Single ship handles THREE stops in a loop
- Auto-refit between cargo types (GRAIN → FOOD)
- Returns to start with partial cargo (farm produces continuously)
- Only ONE deadhead leg (return from town to farm)
- ONE ship sufficient to be profitable

**When to use:**
- Very first route on any water-accessible map (1850+)
- Alternative to Recipe 3 if you have better geometric alignment
- Faster profitability than land-based routes (ships = 90 capacity vs. 5 for early trucks)

**Build Sequence:**

```
Step 1: Identify water-accessible locations
  - Farm with water access (ideally grain production)
  - Food Processing Plant with water access
  - Town dock location with sufficient water depth
  - All three ~2-5km apart (not too close, not too far)

Step 2: Build ports
  ipc.send('build_port', {
    industry_id: FARM_ID,
    water_location: [x1, y1],
    name: "Farm Dock"
  })
  
  ipc.send('build_port', {
    industry_id: FOOD_PLANT_ID,
    water_location: [x2, y2],
    name: "Food Plant Dock"
  })
  
  ipc.send('build_port', {
    town_id: TOWN_ID,
    water_location: [x3, y3],
    name: "Town Dock"
  })

Step 3: Verify water path (CRITICAL)
  ipc.send('check_water_path', {
    from: FARM_DOCK,
    to: FOOD_PLANT_DOCK
  })
  # Must return: water_connected=true, distance=X
  
  ipc.send('check_water_path', {
    from: FOOD_PLANT_DOCK,
    to: TOWN_DOCK
  })
  # Must return: water_connected=true, distance=X

Step 4: Create ship line (triangle loop)
  ipc.send('create_ship_line', {
    name: "Triangle Loop: Farm → Plant → Town",
    stops: [FARM_DOCK, FOOD_PLANT_DOCK, TOWN_DOCK],
    auto_refit: True,
    cargo_types: ['GRAIN', 'FOOD']  # Auto-switch at each stop
  })

Step 5: Add ONE ship (Zoroaster, capacity 90)
  ipc.send('add_vehicle_to_line', {
    line_id: TRIANGLE_LOOP_ID,
    vehicle_type: 'Zoroaster',
    count: 1
  })

Step 6: Set load modes (CRITICAL)
  ipc.send('set_station_load_config', {
    station_id: FARM_DOCK,
    cargo_type: 'GRAIN',
    load_mode: 'FULL_LOAD',
    wait_unlimited: True
  })
  
  ipc.send('set_station_load_config', {
    station_id: FOOD_PLANT_DOCK,
    cargo_type: 'FOOD',
    load_mode: 'FULL_LOAD',
    wait_unlimited: True
  })
  
  ipc.send('set_station_load_config', {
    station_id: TOWN_DOCK,
    cargo_type: 'FOOD',
    load_mode: 'AUTO',
    drop_all: True
  })

Step 7: Optional truck feeder if town dock far from town center
  If town dock is >500m from town center, add:
  
  ipc.send('create_truck_line', {
    name: "Town Final Delivery",
    source: TOWN_DOCK,
    destinations: [TOWN_CENTER_STOPS],
    cargo: 'FOOD',
    num_vehicles: 2,  # Small feeder only
    load_mode: 'LOAD_IF_AVAILABLE',
    max_wait: 60
  })

Step 8: Verify revenue flows
  Wait 1 game month, check:
  - Ship makes complete loop (3 stops)
  - Load bars show full cargo at each step
  - Interval is 60-90 seconds (1 ship is fine)
  - Profit trending positive
```

**Geometric optimization:**

The triangle should ideally form an **equilateral or isosceles shape**, not a straight line:

```
GOOD (triangle):          BAD (straight line):
Farm ──┐                  Farm ── Food Plant ── Town
       │ 2km                      (3km)    (2km)
       Food Plant
       │ 1.5km
       Town

Better ship routing with triangle; ship travels equal distance regardless.
```

**Profitability timeline:**
- Year 1: Generate $300K-$500K profit (ships print money)
- Year 3: Cumulative profit $1M+
- By Year 5: Have $3M saved for first train

**Financial reality from Video 1:** ONE ship is often enough to be profitable. Do not overbuild. Let food plant level up naturally.

**Expansion path:**
- This recipe is COMPLETE by itself (delivers to town = revenue)
- After reaching $3M, transition to Recipe 17 (Multi-Stop Train) for Phase 2
- Keep triangle loop running; it continues to be profitable alongside trains

**Common mistakes:**
- Building three separate P2P routes instead of one loop (1.5x lower efficiency)
- Placing town dock too far inland (prevents ship access)
- Not setting wait mode correctly (ships sit idle)
- Adding more ships immediately (one is sufficient; only add if interval >120s)

**Lesson from Video 1:** "One ship line can be profitable from the very start in 1850." This recipe embodies that principle.

---

## NEW RECIPE 17: Multi-Stop Train Line

### Insert after Recipe 16 in Recipe Catalog

**Add to Quick Reference Table:**

```
| 17 | [Multi-Stop Train Line](#recipe-17-the-multi-stop-train-line) | Intermediate | 1880+ | 3-4 | TOOLS/FUEL | Rail |
```

### Full Recipe Entry

---

### Recipe 17: The Multi-Stop Train Line

**The Video 2 recommended mid-game recipe. A SINGLE train visiting 3-5 stops in sequence, maximizing wagon reuse and minimizing deadhead. The foundation of efficient rail networks.**

```
Forest [logs] ──> Saw Mill [planks] ──> Tools Factory [tools] ──> Town [drop]
        ↑                                                              |
        └──────────────── train returns empty ─────────────────────────┘
```

**Key principle:** ONE train makes a LOOP with cargo at every stop except return. Wagons auto-refit at each processor.

**Prerequisites:**
- Three or four industries/towns in rough LINEAR arrangement (distance 2-10km)
- Choose route with high wagon reuse (all same wagon type preferred)
- Rail service unlocked (year 1880+)
- $2.5M+ available for track + train + stations

**Why it works:**
- Compared to Recipe 9 (P2P lines), this uses ONE train instead of THREE
- Wagons refit at each stop (stakes carry logs, then planks)
- Train returns loaded (not deadhead) on final leg to town
- Lower maintenance (1 train vs. 3)
- Higher utilization (70-80% vs. 50%)

**Wagon efficiency comparison:**

| Setup | Legs | Utilization | Dead legs | Maintenance |
|-------|------|-------------|-----------|-------------|
| 3 separate P2P | 6 | 50% | 3 | $1.8M/month (3 trains) |
| 1 multi-stop loop | 4 | 75% | 1 | $600K/month (1 train) |
| **Improvement** | - | **+25%** | **-67%** | **-67%** |

**When to use:**
- Your first train route (year 1880-1890)
- When you have $2.5M+ saved
- When ship income has covered early expenses
- When you've identified 3-4 industries in linear arrangement

**Build Sequence:**

```
Step 1: Select route with high wagon reuse
  Best routes (by car reuse score):
  1. Crude Oil → Oil Refinery → Fuel Refinery → Town (all tank cars) [Score: 1.0]
  2. Forest → Saw Mill → Tools Factory → Town (mostly stake cars) [Score: 0.67]
  3. Coal + Ore → Steel Mill [Score: 0.5] (AVOID for first train)

Step 2: Plan rail stations
  Forest --[2km]-- Saw Mill --[3km]-- Tools Factory --[2km]-- Town
  
  Note: Roughly linear arrangement (deviation <30%)

Step 3: Build rail stations (2+ platforms MINIMUM)
  ipc.send('build_rail_station', {
    name: "Forest Station",
    industry_id: FOREST_ID,
    platforms: 2,
    depot: True,
    position: [x1, y1]
  })
  
  ipc.send('build_rail_station', {
    name: "Saw Mill Station",
    industry_id: SAW_MILL_ID,
    platforms: 2,
    depot: True,
    position: [x2, y2]
  })
  
  ipc.send('build_rail_station', {
    name: "Tools Factory Station",
    industry_id: TOOLS_FACTORY_ID,
    platforms: 2,
    depot: True,
    position: [x3, y3]
  })
  
  ipc.send('build_rail_station', {
    name: "Town Station",
    town_id: TOWN_ID,
    platforms: 2,
    depot: False,  # Use cargo stations in town, not passenger stations
    position: [x4, y4]
  })

Step 4: Build rail track (tryBuildRoute handles routing)
  # Forest → Saw Mill
  ipc.send('build_rail_track', {
    from_station: FOREST_STATION,
    to_station: SAW_MILL_STATION
  })
  Wait 10-30 seconds for async completion, poll logs
  
  # Saw Mill → Tools Factory
  ipc.send('build_rail_track', {
    from_station: SAW_MILL_STATION,
    to_station: TOOLS_FACTORY_STATION
  })
  Wait 10-30 seconds
  
  # Tools Factory → Town
  ipc.send('build_rail_track', {
    from_station: TOOLS_FACTORY_STATION,
    to_station: TOWN_STATION
  })
  Wait 10-30 seconds

Step 5: Verify track completion
  ipc.send('verify_track_connection', {
    from_station: FOREST_STATION,
    to_station: TOWN_STATION
  })
  # Must return: connected=true

Step 6: Create rail line (ONE line, all stops)
  ipc.send('create_rail_line', {
    name: "Lumber to Tools",
    stations: [FOREST_STATION, SAW_MILL_STATION, TOOLS_FACTORY_STATION, TOWN_STATION],
    num_trains: 1,
    wagons_per_train: 8,
    wagon_type: "stake"  # Majority cargo type
  })

Step 7: Set load modes per STOP (CRITICAL - different for each stop)
  
  # Stop 1: Forest (raw production)
  ipc.send('set_station_load_config', {
    station_id: FOREST_STATION,
    cargo_type: 'LOGS',
    load_mode: 'FULL_LOAD',
    wait_unlimited: True  # Wait for full train
  })
  
  # Stop 2: Saw Mill (intermediate processor)
  ipc.send('set_station_load_config', {
    station_id: SAW_MILL_STATION,
    cargo_type: 'PLANKS',
    load_mode: 'LOAD_IF_AVAILABLE',  # Don't wait forever
    max_wait_seconds: 60
  })
  
  # Stop 3: Tools Factory (final factory)
  ipc.send('set_station_load_config', {
    station_id: TOOLS_FACTORY_STATION,
    cargo_type: 'TOOLS',
    load_mode: 'FULL_LOAD',  # Full load for town delivery
    max_wait_seconds: 60
  })
  
  # Stop 4: Town (delivery)
  ipc.send('set_station_load_config', {
    station_id: TOWN_STATION,
    cargo_type: 'TOOLS',
    load_mode: 'AUTO',
    drop_all: True
  })

Step 8: Scale vehicles (if needed)
  Query initial interval:
  ipc.send('query_lines')
  Find line "Lumber to Tools", check interval
  
  Target interval: 60-90 seconds (1 train is OK for moderate supply)
  
  If interval >120s, add another train:
  ipc.send('add_vehicle_to_line', {
    line_id: LUMBER_TO_TOOLS_ID,
    wagon_type: 'stake',
    count: 1  # Add 1 more train
  })

Step 9: Monitor profitability
  After 1 game year, check:
  - Interval 60-120s (consistent)
  - Load bars show full at each stop
  - Profit trending positive (should see $500K-$2M/year after 3 years)
  - No vehicles stuck or backing up
```

**Load mode reference table (applies to all multi-stop routes):**

| Stop Type | Load Mode | Max Wait | Rationale |
|-----------|-----------|----------|-----------|
| Raw production (forest, mine, farm) | FULL_LOAD | Unlimited | Must accumulate full cargo before leaving |
| Intermediate processor (saw mill, oil refinery, food plant) | LOAD_IF_AVAILABLE | 60s | Processor always has SOME output, don't wait forever |
| Final factory (tools, goods, machines) | FULL_LOAD | 60s | Need full load for town delivery revenue |
| Town delivery (final stop) | AUTO (DROP_ALL) | - | Drop everything, don't load return cargo |

**Wagon configuration (maintain consistency):**

For the Lumber route example:
- **Forest → Saw Mill:** Carry LOGS in stake cars (6 stakes)
- **Saw Mill → Tools Factory:** Same 6 stakes, auto-refit to PLANKS
- **Tools Factory → Town:** Switch to 2 box cars for TOOLS, stakes drop off
- **Return to Forest:** 2 box cars + 6 stakes return (no cargo)

Total: 6 stake cars + 2 box cars = 8 cars, ONE train

**Profitability timeline:**
- Year 1: Negative (infrastructure costs high)
- Year 2-3: Break even
- Year 4-8: Positive ($1-5M/year depending on demand)
- Year 8+: Mature ($5M+/year)

**Scaling rules:**

```
If interval < 60s:
  → System is BOTTLENECKED (good! high demand)
  → Add second train to same line
  → Train 2 will load-balance automatically
  → Can add up to 3-4 trains on same route

If interval 60-120s:
  → PERFECT utilization
  → Leave as-is

If interval > 120s:
  → Under-utilized
  → Remove vehicles OR convert to different cargo
  → Check if source industry is producing enough
```

**Expansion path:**
- After this route becomes profitable (year 3-4), add Recipe 8 or 10 (more complex chains)
- Keep this route running; it continues to be profitable
- Use pattern (multi-stop, car reuse) for all subsequent train routes

**Common mistakes:**
- Building 3 separate P2P lines instead of 1 multi-stop (lose efficiency)
- Using wrong wagon type (auto-detect from line name fails - ALWAYS specify)
- Not setting load modes per stop (trains sit idle)
- Over-wagoning (8 cars is fine; don't add 15)
- Placing town station in city center (causes congestion, slow delivery)

**Lesson from Video 2:** "Choose routes that REUSE CARS. Build ONE line with MULTIPLE stops. Don't use P2P." This recipe embodies those principles.

---

## RECIPE 14 REDESIGN: Hub Circle Network

### Replace entire Recipe 14 entry

**Updated Quick Reference Table entry:**

```
| 14 | [Hub Circle Network](#recipe-14-the-hub-circle-network-redesigned) | Expert | 1920+ | N/A | All | Rail+Road |
```

### Full Redesigned Recipe Entry (heavily modified for Video 3)

---

### Recipe 14: The Hub Circle Network (REDESIGNED)

**MAJOR OVERHAUL per Video 3 (Hushey). This is NOT a circular rail loop anymore. This is a CARGO HUB NETWORK with feeder/processing/distribution lines. The endpoint of the game progression: self-optimizing cargo distribution across the entire map.**

**Old concept (deprecated):** Circular main line visiting all regions. Inefficient cargo distribution.

**New concept (Video 3):** Centralized HUBS (1-4 per map) with three types of lines radiating outward:
- **Feeder lines:** Industries → Hub (raw materials)
- **Processing lines:** Hub ↔ Processors (round-trip)
- **Distribution lines:** Hub → Towns (finished goods)

```
              [Town A]
                 |
    [Forest] --[Hub]-- [Town B]
       |         |         |
    [Mine]  [Processors] [City]
       |         |
    [Farm]--[Trucks]
```

**Prerequisites:**
- Year 1920+ (hub concept requires modern infrastructure)
- 15+ industries on map (otherwise too simple)
- 4+ towns with diverse demands
- At least 1 main rail line or high-speed road network
- $5M+ in reserves (hub infrastructure is expensive)

**Why hubs work (Video 3 insight):**
- Game's cargo "director" distributes cargo intelligently through hub
- One hub can serve 5-10 industries simultaneously
- Single train can carry MIXED cargo (coal + ore + grain on same train)
- Vehicles return FULL instead of deadhead
- Economies of scale: fewer, bigger trains more profitable

**Financial impact:** Hub network generates $10M-$200M/year depending on size (vs. $1-5M for P2P routes).

**Hub network architecture:**

```
┌─────────────────────────────────────────────────────┐
│              MAP with Hub Network                   │
├─────────────────────────────────────────────────────┤
│                                                     │
│  [Forest]        [City A]                [City B]   │
│       |             |                        |      │
│  [FEEDER]    [DISTRIBUTION]           [DISTRIBUTION│
│       |             |                        |      │
│  ┌────┴────────────[HUB ALPHA]────────────────┐    │
│  │                   |                         │    │
│  │              [PROCESSING]                   │    │
│  │                   |                         │    │
│  │  [Steel Mill] [Processors] [Refineries]    │    │
│  │                                             │    │
│  │        [Coal] --[TRUCK FEEDERS]-- [Iron]   │    │
│  │                                             │    │
│  └─────────────────────────────────────────────┘    │
│                                                     │
│  [City C]              [City D]                     │
│       |                     |                       │
│  [DIST LINE]          [DIST LINE]                   │
│       |   ┌───────────────┬────────┬────────┐       │
│       └───┤               │        │        │       │
│    [HUB BETA]────────────[PROCESSORS]───[FARM]     │
│           |                                         │
│      [FEEDER LINES]                                 │
│           |                                         │
│   [Coal] [Iron] [Ore]                              │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Hub placement strategy:**

For each region (1000x1000m section):

1. Identify industry clusters (5+ industries within 2km)
2. Identify town clusters (2+ towns within 3km)
3. Place hub at GEOMETRIC CENTER between industries and towns
4. Connect all local industries via FEEDERS
5. Connect processors via PROCESSING LINES
6. Connect towns via DISTRIBUTION LINES

```python
def find_optimal_hub_location(industries, towns):
    """Find geographic center between industries and towns"""
    ind_center = calculate_centroid(industries)
    town_center = calculate_centroid(towns)
    
    # Hub should be between them, slightly closer to industries
    hub_x = (ind_center.x * 0.6 + town_center.x * 0.4)
    hub_y = (ind_center.y * 0.6 + town_center.y * 0.4)
    
    return [hub_x, hub_y]
```

**Build sequence:**

### Phase 1: Build hub station (6-track minimum)

```
ipc.send('build_rail_station', {
    name: "Regional Hub Alpha",
    platforms: 6,
    tracks: 6,
    depot: True,
    cross_switches: True,
    position: [hub_x, hub_y],
    storage_capacity: 999999  # Unlimited cargo
})
```

**Hub station interior design (conceptual):**

```
Track 1: [Incoming Feeders] - Raw materials arrive here
Track 2: [Incoming Feeders] - More raw materials
Track 3: [Processing Lines] - Round-trip to processors
Track 4: [Processing Lines] - More processors
Track 5: [Distribution] - Outbound to towns
Track 6: [Distribution] - More town routes
```

### Phase 2: Build feeder lines (Industries → Hub)

**Characteristics:**
- Short routes (<5km ideal)
- Trucks or trains depending on distance
- Full load mode (wait unlimited)
- Target interval: 30-45s (faster than normal 60s)

**IPC for truck feeder (nearest industries):**

```
# For each industry within 5km of hub
for industry in industries_within(hub, 5000):
    ipc.send('create_truck_line', {
        name: f"Feeder: {industry.name} → Hub",
        source: industry.id,
        destination: hub_id,
        cargo: 'AUTO',  # Any cargo
        num_vehicles: 4,  # Start with 4, scale as needed
        load_mode: 'FULL_LOAD',
        wait_unlimited: True
    })

# For industries 5-15km away, use TRAIN feeders instead
for industry in industries_within(hub, 15000):
    if distance(industry, hub) > 5000:
        ipc.send('create_rail_line', {
            name: f"Feeder: {industry.name} → Hub",
            stops: [industry_station, hub_station],
            cargo: 'AUTO',
            num_trains: 1,
            wagons: 6
        })
```

**Industries 500m from hub = AUTO-CONNECT (no truck needed per Video 3):**

```python
# Identify auto-connected industries (within 500m)
auto_connected = [ind for ind in industries 
                 if distance(ind, hub) <= 500]

# These industries automatically trade with hub
# No truck/train line needed!
```

### Phase 3: Build processing lines (Hub ↔ Processors)

**Characteristics:**
- Round-trip: Hub → Processor → Hub
- Cargo out (raw materials), return (finished goods)
- Processor stations 1-3km from hub
- Trucks preferred for processors closer to hub

**IPC for processor round-trip:**

```
# Steel Mill example
ipc.send('create_truck_line', {
    name: "Steel Processing: Hub ↔ Steel Mill",
    stops: [hub_id, steel_mill_id, hub_id],
    cargo_outbound: ['IRON_ORE', 'COAL'],  # Truck OUT carries raw
    cargo_return: 'STEEL',  # Truck BACK carries steel
    num_vehicles: 5,
    load_mode_outbound: 'LOAD_IF_AVAILABLE',
    load_mode_return: 'FULL_LOAD'
})

# Another processor (e.g., Tools Factory)
ipc.send('create_truck_line', {
    name: "Tools Processing: Hub ↔ Tools Factory",
    stops: [hub_id, tools_factory_id, hub_id],
    cargo_outbound: ['PLANKS', 'STEEL'],
    cargo_return: 'TOOLS',
    num_vehicles: 4
})
```

**Scale feeders to 30-45s interval (feeders are bottleneck):**

```python
def scale_feeder_vehicles(line_id, target_interval=40):
    """Add vehicles until interval reaches target"""
    while True:
        line = query_line(line_id)
        if line.interval <= target_interval:
            break
        
        ipc.send('add_vehicle_to_line', {
            line_id: line_id
        })
        
        time.sleep(5)  # Wait for game to process
```

### Phase 4: Build distribution lines (Hub → Towns)

**Characteristics:**
- LARGE trains with high capacity
- Visit multiple towns in sequence
- Carry MIXED finished goods (whatever towns demand)
- Return empty OR with passenger traffic

**IPC for multi-town distribution:**

```
ipc.send('create_rail_line', {
    name: "Distribution: Hub → Cities",
    stops: [hub_id, town_a_id, town_b_id, town_c_id],
    cargo_types: ['FOOD', 'TOOLS', 'GOODS', 'FUEL', 'MACHINES'],
    num_trains: 3,  # Multiple trains for throughput
    wagons_per_train: 12,
    wagon_type: 'box'  # Universal finished goods wagon
})

# Set load modes
ipc.send('set_station_load_config', {
    station_id: hub_station,
    load_mode: 'LOAD_MIXED',  # Load all demanded cargo types
    wait_seconds: 60
})

for town in [town_a_id, town_b_id, town_c_id]:
    ipc.send('set_station_load_config', {
        station_id: town,
        load_mode: 'DROP_ALL',
        return_cargo: 'NONE'  # No return cargo
    })
```

**Last-mile truck delivery (Video 3 critical principle):**

```
# Do NOT run cargo trains into city center!
# Instead: Cargo station at BORDER, small trucks deliver WITHIN city

ipc.send('build_truck_station', {
    name: f"City Border Distribution: {town.name}",
    town_id: town_id,
    position: [city_border_x, city_border_y],  # Just outside city zone
    cargo_types: ['FOOD', 'TOOLS', 'GOODS', 'FUEL']
})

ipc.send('create_truck_line', {
    name: f"City Delivery: {town.name}",
    source: city_border_station,
    destinations: [district_1, district_2, district_3],
    cargo: 'AUTO',
    num_vehicles: 3,  # Small trucks ONLY
    load_mode: 'LOAD_IF_AVAILABLE',
    max_wait: 30
})
```

**Impact of last-mile trucks:**
- Cargo trains stay OUTSIDE city (clean)
- City traffic unaffected
- Truck utilization 60%+ (vs. 15% if running across entire map)

### Phase 5: Multi-hub scaling (for large maps >2000x2000m)

**Divide map into regions, build hub per region:**

```
Region breakdown (example 2000x2000m map):
  NW Region [1000,1000] → Hub North
  NE Region [1000,1000] → Hub North-East
  SW Region [1000,1000] → Hub South-West
  SE Region [1000,1000] → Hub South-East

Connect hubs with high-capacity inter-hub trains:
  Hub North ↔ Hub South (RAIL, capacity 12 wagons, mixed cargo)
  Hub North ↔ Hub East (RAIL, capacity 12 wagons)
  ... (form complete ring or grid)
```

**IPC for inter-hub connection:**

```
ipc.send('create_rail_line', {
    name: "Inter-Hub Transfer: North ↔ South",
    stops: [hub_north_id, hub_south_id],
    cargo_types: 'AUTO',  # Any/all cargo
    num_trains: 2,
    wagons_per_train: 12,
    route_straight: True  # Main line, straight routing
})
```

**Scaling benefit:** New industries just need feeder to nearest hub; inter-hub trains handle distribution automatically.

---

## Updated Recipe Selection Flowchart

Replace existing flowchart in 05_RECIPES.md with this VIDEO-INFORMED version:

```
START: RECIPE SELECTION FLOWCHART
  |
  ├─ QUESTION 1: What game year is it?
  │   ├─ 1850-1880 → PHASE 1 (Ships)
  │   │   ├─ Do you have water access on map?
  │   │   │   ├─ YES → Recipe 3: Ship Start OR Recipe 16: Triangle Ship Loop
  │   │   │   │   └─ IF geometry forms triangle: Use Recipe 16 (higher profit)
  │   │   │   │   └─ IF simple P2P: Use Recipe 3
  │   │   │   │
  │   │   │   └─ NO → Recipe 6: Food + ConMat Combo
  │   │   │       └─ Prepare for trains by year 1880
  │   │   │
  │   │   └─ GOAL: Accumulate $3M for train transition
  │   │
  │   ├─ 1880-1920 → PHASE 2 (Trains)
  │   │   ├─ Do you have $3M+ liquid cash?
  │   │   │   ├─ NO → Build more ships or Recipe 6 until $3M saved
  │   │   │   │
  │   │   │   └─ YES → Select train route
  │   │   │       ├─ SCORE route for wagon reuse (Video 2 principle)
  │   │   │       │   ├─ Score 1.0 (all same wagons) → Recipe 8: Black Gold Pipeline
  │   │   │       │   ├─ Score 0.6-0.8 → Recipe 7: Lumber Run OR Recipe 17: Multi-Stop
  │   │   │       │   └─ Score <0.5 → Skip, find better route
  │   │   │       │
  │   │   │       └─ Build Recipe 17: Multi-Stop Train Line (Video 2 primary)
  │   │   │           └─ Pattern: Forest → Mill → Factory → Town
  │   │   │               One train, multiple stops, car reuse
  │   │   │
  │   │   └─ GOAL: Build 3-5 train routes, establish car-reuse pattern
  │   │
  │   └─ 1920+ → PHASE 3 (Hubs)
  │       ├─ Have you built 10+ rail lines?
  │       │   ├─ NO → Continue Phase 2, build more trains
  │       │   │
  │       │   └─ YES → Transition to Recipe 14: Hub Network
  │       │       ├─ REDESIGN existing routes into hub architecture
  │       │       │   ├─ Identify hub location (map center or region center)
  │       │       │   ├─ Convert industries to FEEDER lines (trucks to hub)
  │       │       │   ├─ Add PROCESSING lines (hub ↔ processors)
  │       │       │   ├─ Add DISTRIBUTION lines (hub → towns)
  │       │       │   └─ Use last-mile trucks for city delivery (Video 3 critical)
  │       │       │
  │       │       └─ For large maps (>30 industries):
  │       │           └─ Build multiple hubs (1 per region)
  │       │           └─ Connect hubs with inter-hub trains
  │       │           └─ Each hub serves local region
  │       │
  │       └─ GOAL: Self-optimizing network, scales infinitely
  │
  └─ QUESTION 2: Do you have an INCOMPLETE chain?
      (intermediate cargo, not delivered to town = NO REVENUE)
      └─ YES → STOP. Extend existing chain to town FIRST.
               (Never leave intermediate-only chains running)
      └─ NO → Proceed with new route selection

KEY DECISION RULES (from videos):
- Ship Triangle Loop (Video 1): Water-adjacent + triangle geometry = Recipe 16
- Multi-Stop Train (Video 2): 3+ stops + car reuse scoring = Recipe 17
- Hub Network (Video 3): Year 1920+, 10+ lines, ready to consolidate = Recipe 14 redesigned
- Capacity over Frequency (Video 3): 1 big train > 8 small trucks
- Cargo hubs (Video 3): Centralize, let game director optimize
- Last-mile delivery (Video 3): Border stations + small trucks INTO city
```

---

## NEW Anti-Patterns Section

Add this new section to PRD 05_RECIPES.md after "Financial Guard Rails":

### Anti-Patterns: Mistakes from Video 3 (Hushey)

These strategies have been analyzed in videos and PROVEN to fail:

#### Pattern 1: Direct Industry-to-Town Routes (All Cargo)

**Definition:** Every industry has a separate direct route to each town demanding its output.

**Symptoms:**
- 30+ individual routes on the map
- Industries can't trade with each other
- Hub station sits empty (if built)
- Scaling becomes impossible (new industry = new set of routes)

**Why it fails:** Doesn't leverage cargo director. Game can't optimize routing.

**Fix (Video 3):** Build cargo hub network instead. Route ALL cargo through hub; director optimizes distribution.

**From Hushey:** "Most efficient way to handle cargo is using a cargo hub."

---

#### Pattern 2: Long-Distance Truck Routes for Bulk Cargo

**Definition:** Using trucks for cargo >5km (e.g., 10 trucks hauling coal 8km to steel mill).

**Symptoms:**
- 15-20 trucks on single route
- Vehicles get stuck in terrain
- Maintenance costs exceed revenue
- "Why is this route losing money?"

**Why it fails:** Truck maintenance scales with vehicle count. 15 trucks cost $2M+/month; route only earns $500K/month.

**Fix (Video 3):** Use trains for >5km. Trucks only for <5km feeders to hub.

**From Hushey:** "Don't use trucks for long distance cargo. Use trains."

---

#### Pattern 3: Mixed Cargo/Passenger Transport

**Definition:** Same train carries both cargo and passengers (e.g., "Mixed Goods & Passengers").

**Symptoms:**
- Trains partially loaded with cargo, partially with passengers
- Low utilization on both (crowding)
- Slow trains (cargo slows down passengers)
- Profit lower than expected

**Why it fails:** Cargo and passengers have opposite needs (frequency vs. capacity). Mixing compromises both.

**Fix (Video 3):** Separate lines entirely. Cargo trains ≠ passenger trains.

**From Hushey:** "Don't mix cargo and passenger transport."

---

#### Pattern 4: Cargo Stations in City Center

**Definition:** Building cargo stations and truck routes through downtown city blocks.

**Symptoms:**
- Trucks move at 10% speed (city traffic jam)
- Delivery interval >300 seconds (vs. target 60s)
- Cargo builds up (demand not met)
- City population fails to grow

**Why it fails:** City traffic creates massive congestion. Vehicle movement speed plummets.

**Fix (Video 3):** Build cargo stations at city BORDER. Use small trucks for final delivery within city only.

**From Hushey:** "Cargo stations should be at city border, not city center."

---

#### Pattern 5: Hub Station Too Small

**Definition:** Building hub with 2-3 platforms (treats it like normal station).

**Symptoms:**
- Trains queue for 30+ game minutes
- Cargo flows slowly
- Hub becomes bottleneck instead of distributor
- Expansion blocked

**Why it fails:** Hub sees 10-20 trains per day across multiple lines. Insufficient platforms = massive queuing.

**Fix (Video 3):** Build hub with 6+ tracks, 4-6 platforms per track. Oversized capacity by default.

**From Hushey:** "6-track station minimum for the main hub."

---

#### Pattern 6: Too Many Small Vehicles Instead of One Large Train

**Definition:** Using 8 small trains with 4 wagons each instead of 1 large train with 12 wagons.

**Symptoms:**
- Maintenance $2M+/month for same capacity as 1 large train
- Profit margin negative
- "Why am I going bankrupt?"

**Why it fails:** Each train has base maintenance cost. 8 trains = 8x cost. 1 train = 1x cost.

**Fix (Video 3):** Use capacity, not frequency. 1 big train is always cheaper than 8 small ones for cargo.

**From Hushey:** "One high-capacity train > many small trains."

---

#### Pattern 7: Not Delivering ALL Demanded Cargo Types to Towns

**Definition:** City demands FOOD+TOOLS+GOODS, but you only deliver FOOD.

**Symptoms:**
- City growth stalled
- Demand for other goods unfulfilled
- Profit lower than should be
- Other players' cities outgrow yours

**Why it fails:** Towns need MULTIPLE cargo types to grow. Partial supply = partial growth.

**Fix (Video 3):** Deliver ALL demanded cargo types to each town. Use hub network to distribute mixed cargo.

**From Hushey:** "Never forget to deliver ALL demanded cargo types to cities."

---

#### Pattern 8: Industries Too Far From Hub (>15km)

**Definition:** Building hub at map center, but having industries 20km away.

**Symptoms:**
- Very long truck/train feeders
- High travel time (120+ seconds per leg)
- Bottleneck forms
- Scaling breaks down

**Why it fails:** Distance multiplies transit time. 20km feeder = 2-3 minute round trip. Hub loses advantage.

**Fix (Video 3):** Build multiple regional hubs (1 per region). Keep all feeders <5km from their hub. Max feeder distance: 15km for trains, 5km for trucks.

**From Hushey:** "Place hub BETWEEN industry clusters and towns."

---

## Summary of All Updates

| Item | Status | Location |
|------|--------|----------|
| Recipe 16: Triangle Ship Loop | NEW | Insert after Recipe 15 |
| Recipe 17: Multi-Stop Train Line | NEW | Insert after Recipe 16 |
| Recipe 14: Hub Circle Network | REDESIGN | Replace entire recipe |
| Recipe Selection Flowchart | UPDATE | Incorporate video guidance |
| Anti-Patterns | NEW SECTION | Add after Financial Guard Rails |

**Implementation order:**
1. Insert Recipe 16 and 17 into Quick Reference table
2. Add Recipe 16 full entry (~300 lines)
3. Add Recipe 17 full entry (~400 lines)
4. Replace Recipe 14 entirely (~500 lines)
5. Replace Recipe Selection Flowchart
6. Add Anti-Patterns section (~300 lines)

**Total additions:** ~1500 lines of new content, significantly expanded PRD 05_RECIPES.md.

