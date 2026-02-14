# PRD 06: Video Strategy Guide - Advanced Tactics from KatherineOfSky & Hushey

## Document Overview

This PRD synthesizes strategies from three foundational YouTube tutorials on Transport Fever 2 cargo networks:

1. **KatherineOfSky - "GUARANTEED PROFITABLE CARGO START! (1850), Part 1: Ships"** (16:28)
   - Early-game ship strategy for 1850 start
   - Ship triangle loop concept
   - Truck feeder integration

2. **KatherineOfSky - "GUARANTEED PROFITABLE CARGO START! (1850), Part 2: Trains"** (38:11)
   - First train route design and car reuse principles
   - Multi-stop train line concept
   - Vehicle scaling and station design
   - Financial sequencing from ships to trains

3. **Hushey - "You're Doing Cargo WRONG! BEST Automatic Cargo Explained"** (16:54)
   - Cargo hub network concept for late-game scaling
   - Hub design, feeder/processing/distribution lines
   - Capacity-over-frequency principle
   - Multi-region hub scaling

**Purpose:** These videos contain tactical insights NOT fully captured in PRD 05_RECIPES.md. This guide bridges that gap and provides implementation guidance for the AI system.

---

## Part 1: Early Game - Ship Start (1850) - Video 1

### Context: Why Ships First?

In 1850-1880, transport options are severely limited:
- **Carriages**: ~50 km/h, 5 unit capacity, high maintenance
- **Ships**: 90 unit capacity (Zoroaster), auto-refit, zero waterway cost
- **Rail**: Not available until 1880 at earliest, extremely expensive

**Key insight from video:** Ships are the ONLY viable transport for bulk cargo in 1850. Early games MUST prioritize water access.

### Map Selection Criteria (NEW)

Before committing to a map, analyze these factors:

| Criterion | Good | Bad |
|-----------|------|-----|
| Number of cities | 12+ cities | <6 cities |
| Industry count | 8-15 industries (low) | >30 industries (high) |
| Map size | Very large (full exploration needed) | Small/medium |
| Water access | Rivers or coast covering >20% | Isolated inland clusters |
| Industry placement | Clustered near water | Scattered inland |
| City placement | Spread across map | Clustered in one area |

**Selection strategy:** Don't just load any map. Spend 2-3 minutes analyzing the starting view, checking water routes, and verifying industry-city proximity before accepting the map.

**IPC check:** Implement a map analysis routine:
```python
# Pseudo-code for AI system
def analyze_map():
    industries = query_all_industries()
    cities = query_all_cities()
    water_routes = check_water_connectivity()
    
    if len(cities) < 12 or len(water_routes) < 5:
        return "MAP_UNSUITABLE"  # Decline and retry
    
    return calculate_feasibility_score()
```

### The Ship Triangle Loop (NEW Recipe 16)

**Definition:** A three-stop ship route forming a loop: Farm dock → Processor dock → Town dock → back to Farm.

**Cargo flow:**
```
Step 1: Ship loads GRAIN at farm dock (capacity 90, arrives with some grain available)
Step 2: Ship sails to food processing plant dock, drops GRAIN
Step 3: Ship waits for food to be produced (food plant processes the grain)
Step 4: Ship loads FOOD at food processing plant dock
Step 5: Ship sails to town dock, drops FOOD (REVENUE POINT)
Step 6: Ship returns to farm, route repeats
```

**Why it works:**
- Single ship carries ALL cargo (grain + food)
- Auto-refit handles cargo type switching
- Only ONE empty leg per loop (return trip from town to farm)
- No intermediate truck lines needed if farm, plant, and town are water-adjacent

**Perfect scenario from Video 1:**
- Farm near river with dock
- Food processing plant 2-3km away, also on water
- Town dock reachable from food plant
- One Zoroaster ship handles entire loop

**Geometric constraint:** The three locations should form a rough triangle with water between them. If they're in a straight line, you lose efficiency (ship travels same distance regardless).

**Financial reality from video:** One ship alone is enough to be profitable from 1850 start. This is NOT a setup route; this is a complete, self-contained income generator.

**See also:** Recipe 3 (Ship Start), Recipe 4 (River Food Run) in 05_RECIPES.md

---

### Truck Station Placement (Enhanced)

**Critical principle from Video 1:** Never put truck stations inside towns.

**Why:** Traffic congestion inside city zones causes vehicles to move at 10-20% speed, killing utilization.

**Correct approach:**
```
Farm/Plant  [Dock at farm]
                |
            Ship route
                |
        [Dock at food plant]
                |
         [Truck station OUTSIDE town border]
                |
        [Final delivery INTO city]
```

**Specific tactics:**
1. **Identify city boundary:** Use terrain visualization to see city zone edges
2. **Build truck station just outside:** Place it at ~200-300m from city edge
3. **Short truck routes only:** Trucks go from outside station into city (5-10 stops max)
4. **Full load + wait settings:**
   - At dock: `load_mode: FULL_LOAD, wait_time: UNLIMITED`
   - At town distribution stops: `load_mode: LOAD_IF_AVAILABLE, wait_time: 60s`

**Benefit:** Trucks spend <10% of time stuck in traffic, achieving 80%+ utilization.

---

## Part 2: Mid Game - First Trains (1880) - Video 2

### Context: Train Economics Reality

**Raw numbers from Video 2:**
- Single train: ~$1.5M purchase price
- Track infrastructure: $50K-$100K per km depending on terrain
- Complete first train setup: $2.5M-$3.5M minimum
- ROI timeline: 5-8 game years before strong profitability

**Critical constraint:** Must have $3M liquid cash BEFORE building first train. Ship income funds this savings.

**Financial sequencing from video:**
```
Year 1-3: Build and optimize ship routes (generate $500K-$1M/year)
Year 3-5: Pay off all loans, accumulate reserves
Year 5: Have $3M+ saved up
Year 5+: Build first train routes
```

**See also:** Recipe 9 (Rail Trunk with Truck Feeders), Recipe 10 (Steel Payday) in 05_RECIPES.md

---

### Car Reuse Priority (NEW Principle)

**The single biggest efficiency gain in train design:** Reusing wagons across multiple legs.

**Poor design (50% deadhead):**
```
Coal Mine [gondola] -> Steel Mill
            (full on leg 1, empty return = 50% utilization)
```

**Good design (100% utilization on revenue legs):**
```
Crude Oil [tank] -> Oil Refinery [tank] -> Fuel Refinery [tank] -> Town
(All tank cars. Full crude out, full oil out, full fuel out = 3 revenue legs, 0% deadhead)
```

**Scoring car reuse routes:**

| Route | Wagon Type | Reusability | Score |
|-------|-----------|------------|-------|
| Wood → Lumber → Tools | Stake/Box car | Partial (wood is stake, tools is box) | 2/3 |
| Crude → Oil → Fuel | Tank car | Complete (all tank) | 3/3 (GOLDEN) |
| Iron Ore → Steel | Gondola | N/A (single leg) | 1/2 |
| Coal → Steel + Coal → Steel → Goods | Gondola + Box | Poor mix | 1/3 |

**Selection algorithm:**
```python
def score_route_for_train(source, dest_list):
    """Score how many legs use same wagon type"""
    wagon_types = []
    for cargo in get_cargos_on_route(source, dest_list):
        wagon_types.append(get_wagon_type(cargo))
    
    unique_types = len(set(wagon_types))
    total_legs = len(dest_list)
    
    # Score = fraction of legs with same wagon type
    # 1.0 = all same, 0.5 = half and half
    return (total_legs - unique_types + 1) / total_legs
```

**Route candidates (best-to-worst):**
1. **Crude → Oil → Fuel** (Score: 1.0) - All tank cars
2. **Wood → Lumber → Tools** (Score: 0.67) - Mostly stake cars
3. **Ore + Coal → Steel → Goods** (Score: 0.5) - Mixed gondola/box
4. Single-leg routes (Score: 0.5) - Heavy deadhead

**Strategy:** Always choose routes with score >0.6. Avoid routes with score <0.4.

---

### Multi-Stop Train Lines (NEW Recipe 17)

**Concept from Video 2:** Instead of separate P2P lines, build ONE line visiting 3-5 stops in sequence.

**Example from video (Forest → Tools → Town chain):**
```
Line "Lumber to Tools":
  Stop 1: Forest    [Drop nothing, load LOGS, full load, wait unlimited]
  Stop 2: Saw Mill  [Drop LOGS, load PLANKS, load if available, wait 60s]
  Stop 3: Tools Factory [Drop PLANKS, load TOOLS, full load, wait 60s]
  Stop 4: Town      [Drop TOOLS, load nothing]
  -> Returns to Stop 1 automatically
```

**Wagon configuration:**
- Forest: 4-6 stake cars (carries logs)
- Saw Mill: 4-6 stake cars (carries planks) - SAME CARS auto-refit
- Tools Factory: 2-3 box cars (carries tools) - different cars load here
- Total: 6-8 cars, ONE train

**Why better than P2P:**
- Single train visits 4 stops vs. three separate trains
- Wagons refit at each stop, maximizing utilization
- Returns are LOADED instead of deadhead
- Lower maintenance (1 train instead of 3)

**Load settings per stop type:**
| Stop Type | Load Mode | Wait Time | Reason |
|-----------|-----------|-----------|--------|
| Raw production (forest, mine) | FULL_LOAD | Unlimited | Must wait for full production |
| Intermediate processor (sawmill, refinery) | LOAD_IF_AVAILABLE | 60s max | Some cargo always available, can't wait forever |
| Final factory (tools, goods) | FULL_LOAD | 60s | Need full load to maximize town delivery |
| Town delivery | AUTO | - | Drop all, load nothing |

**Scale:** Start with 1 train. If interval >120s, add a second train to the same line (game will load-balance automatically).

**Profitability:** Multi-stop lines become profitable in 7-10 game years. Higher value than ships but slower ROI.

---

### Station Design Principles (Enhanced)

From Video 2, specific station architecture matters:

**Station layout:**
```
     Depot area
           |
    [2+ platforms]  <- trains park here
           |
    [Cross-switch]  <- allows trains to use any platform
           |
    [Industry nearby]  <- goods transfer point
```

**Platform count:** Minimum 2 platforms per station. This allows one train to load/unload while another is in queue.

**Cross-switch design:** Implement "railway junction logic" where switches allow trains from either direction to access any platform.

**Depot placement:** Put maintenance depot 1-2 squares from the station, not integrated. This prevents vehicle congestion.

**Avoid:** 
- Stations with 1 platform (creates bottleneck)
- Stations integrated with industry (blocks expansion)
- Stations at town center (causes congestion)

---

## Part 3: Late Game - Cargo Hub Network (1920+) - Video 3

### Context: Hub Networks for Scaling

By 1920+, the map has many industries (20-50+). Managing individual P2P chains becomes impossible:
- Too many lines to monitor
- Cargo mismatches (industry produces X but town wants Y)
- Scaling requires new infrastructure for each new industry

**Hushey's solution:** Centralized hub network where ALL cargo flows through sorting stations.

**Advantage:** Cargo "director" (game's AI) distributes goods intelligently. One hub can serve 5-10 industries simultaneously.

**See also:** Recipe 14 (Hub Circle Network) in 05_RECIPES.md - this guide ENHANCES that recipe.

---

### Cargo Hub Concept (NEW)

**Definition:** A large train station with 6+ platforms that acts as a warehouse/distribution point. All cargo comes TO the hub, then redistributes OUT to processors and towns.

**Hub locations on map:**
```
     Town A          Town B
        |              |
     Quarry        Food Plant   <- Industries clustered near hub
        |              |
        └─────[HUB]────┘        <- Central sorting station
        |              |
        |              |
   Forest Cluster  Coal Mine    <- More industries fed by trucks
        |              |
        └──────────────┘
```

**Why hubs work better than direct routes:**
- Game's cargo director can cross-trade between industries
- Single train can carry mixed cargo (coal + ore + grain on same train)
- Buses and trucks return with FULL loads of outbound cargo
- Economies of scale: fewer, bigger trains are more profitable

**Economic impact from video:** Hub network can generate $200M+ per route (vs. $1-5M for P2P routes).

---

### Hub Design Specifics (NEW)

**Minimum hub station specs:**
- **6 tracks minimum** (4-6 platforms per track)
- **Input area:** 2-3 platforms for incoming raw materials
- **Processing area:** 2-3 platforms for processor feeders
- **Output area:** 1-2 platforms for town deliveries

**Placement strategy:**
```
Place hub:
  [X] BETWEEN industry cluster and town cluster (minimize travel)
  [X] On main rail line (not a branch)
  [X] Near water if possible (for ship access)
  [ ] NOT in city center (causes congestion)
  [ ] NOT at a single industry (hub should serve multiple)
```

**Truck access to hub:** Build small truck stations near hub for industry feeders.

**Benefit:** Trucks achieve 60%+ utilization (vs. 15% if running across entire map).

**Critical:** Do NOT run full cargo trains through city. If necessary, break up at city border and transfer to small trucks.

---

### Three Line Types at Hub (NEW)

Hushey describes three distinct line types flowing through a hub:

#### 1. Feeder Lines (Raw Materials TO Hub)

**Purpose:** Bring raw cargo from source industries to hub for aggregation.

**Characteristics:**
- Trucks or trains from scattered industries to hub
- Full load mode (must collect full wagonload before leaving)
- Wait unlimited at source (industries produce slowly)
- Short routes preferred (<5km)

**Vehicle count:** Scale so that interval is 30-45 seconds (faster than 60s because raw materials are bottleneck).

#### 2. Processing Lines (Hub ↔ Processor)

**Purpose:** Move cargo from hub to processor, then collect finished goods back to hub.

**Characteristics:**
- Round-trip: Hub delivers raw material to processor, picks up finished goods on return
- Processor stations should be 1-3km from hub
- Load modes:
  - At hub: `LOAD_IF_AVAILABLE` (mixed cargo), wait 60s
  - At processor: `FULL_LOAD` (wait for processor output), wait unlimited
- Return trip carries finished goods back to hub

**Example (Steel chain):**
```
Hub [load iron ore + coal] --trucks--> Steel Mill [unload raw, load steel] --trucks--> Hub [unload steel]
```

#### 3. Distribution Lines (Hub TO Towns)

**Purpose:** Deliver finished goods from hub to multiple towns.

**Characteristics:**
- Large trains with high capacity (opposite of feeders)
- Visit multiple towns on single line
- Carry mixed finished goods (FOOD, TOOLS, GOODS, FUEL - all on same train)
- Return empty or with passenger traffic

**Example:**
```
Hub [load FOOD + TOOLS + GOODS + FUEL] --large train--> Town A [drop] --> Town B [drop] --> Town C [drop] --> Hub
```

**Vehicle specs:**
- Use LARGEST trains available in current era
- 8-12 wagons per train
- Multiple trains on same line to handle all demand

---

### Capacity Over Frequency (NEW Principle)

**Critical insight from Video 3:** For CARGO, use BIG trains. Use MANY vehicles only as last resort.

**Wrong approach (high frequency, low capacity):**
```
5 small trains, 4 wagons each
Running every 30 seconds
Total capacity: 20 units/30s = 0.67 units/sec
Maintenance: $2.5M/month for 5 trains
```

**Right approach (low frequency, high capacity):**
```
1 large train, 12 wagons
Running every 30 seconds (same frequency!)
Total capacity: 60 units/30s = 2.0 units/sec
Maintenance: $600K/month for 1 train
Profit: +$1.9M/month vs. 5 small trains
```

**Decision rule:**
```python
if cargo_demand > current_capacity:
    if current_train_wagons < 10:
        add_wagons_to_train()  # Cheaper than another train
    else:
        add_train_to_line()  # Only if already maxed wagon count
```

**Exception:** Passenger transport is opposite - frequency matters more than capacity. But this guide is cargo-focused.

---

### Last-Mile Truck Delivery (NEW)

**Principle from Video 3:** Never run cargo trains into city centers. Always use small trucks for final delivery.

**Correct architecture:**
```
[Hub] --large train--> [Cargo Station at City Border] --small trucks--> [City Distribution]
```

**Truck specifications for city delivery:**
- **Vehicle count:** 2-3 trucks (NOT 20)
- **Capacity:** Small trucks (different from cargo trucks)
- **Routes:** Only within city bounds (5-20 stops)
- **Load mode:** `LOAD_IF_AVAILABLE` with 30s max wait
- **Cargo types:** All demanded cargos in rotation

**Benefit:** Trucks achieve 60%+ utilization (vs. 15% if running across entire map).

---

### Industry Walking Distance Exploitation (NEW)

**Concept from Video 3:** Industries within ~500m of a station "auto-connect" and can trade cargo.

**Advantage:** Save truck routes by placing industries near hub.

**Strategy:**
```
1. Build hub at [1000, 1000]
2. Look for industries within 500m radius
3. Industries in this radius = auto-connect to hub
4. No truck route needed for auto-connected industries
5. Cargo flows automatically
```

**Application:** When planning hub networks, cluster processors near the hub rather than building long truck feeders.

---

### Multi-Hub Scaling (NEW)

**For maps with >30 industries:** Single hub becomes bottleneck. Solution is regional hubs.

**Architecture:**
```
     Hub North
     /      \
  Town 1   Town 2
  
     Hub South
     /      \
  Town 3   Town 4

[Inter-hub train connecting North <-> South]
```

**Strategy:**
1. Divide map into 2-4 regions
2. Build one hub per region at strategic location
3. Each hub serves local industries/towns in that region
4. Connect hubs with high-capacity trains for inter-regional cargo exchange
5. New industries just route to nearest hub

**Example scaling:**
- Map size: 2000x2000m
- Hub density: 1 hub per 1000x1000m region
- Max: 4 hubs for large map

**Advantage:** Scales infinitely. New industries just get feeder to nearest hub; inter-hub trains handle the rest.

---

## Strategy Progression Path

### The Three-Phase Progression

Use these videos in sequence as your game progresses:

```
Phase 1: 1850-1880 (Video 1 - Ship Start)
├─ Focus: Build 1-2 ship routes
├─ Income: $500K-$2M/year
├─ Preparation: Accumulate $3M for trains
└─ Outcome: Profitable fleet, zero loans

Phase 2: 1880-1920 (Video 2 - First Trains)
├─ Focus: Transition to multi-stop rail routes
├─ Income: Ship income + $1M-$5M from train routes
├─ Preparation: Build 2-4 strong train routes, establish car-reuse pattern
└─ Outcome: Mature rail network, higher profit

Phase 3: 1920+ (Video 3 - Hub Networks)
├─ Focus: Consolidate into 1-4 regional hubs
├─ Income: $5M-$200M/year depending on hub design
├─ Preparation: Convert P2P routes to feeder/processing/distribution lines
└─ Outcome: Self-optimizing network, minimal management
```

### Transition Triggers

| Phase | Trigger to Move | Condition |
|-------|---|---|
| Ship → Train | Have $3M+ liquid cash, all loans paid, year ≥1880 | Ships generating $1M+/year |
| Train → Hub | Have 10+ rail lines established, year ≥1920, hub station built | Revenue >$10M/year |

### Recipe Selection by Phase

**Phase 1 (Ships):**
- Recipe 3: Ship Start (early water routes)
- Recipe 4: River Food Run (if water-accessible)
- Recipe 6: Food + ConMat Combo (support ships with road)

**Phase 2 (Trains):**
- Recipe 7: Lumber Run (3-stage train, moderate complexity)
- Recipe 8: Black Gold Pipeline (4-stage train, high value)
- Recipe 9: Rail Trunk with Truck Feeders (long-distance)
- Recipe 10: Steel Payday (advanced chain)

**Phase 3 (Hubs):**
- Recipe 14: Hub Circle Network (convert existing to hub model)
- Recipe 15: Tropical Ship Network (if water-heavy map)
- Multi-hub scaling (new hubs added as needed)

---

## Summary of KEY NEW STRATEGIES

| Strategy | Source | Type | Impact |
|----------|--------|------|--------|
| Ship Triangle Loop | Video 1 | Early game | 1 ship handles 3 stops, high utilization |
| Truck stations OUTSIDE towns | Video 1 | All phases | Improves truck utilization 4x |
| Car reuse scoring | Video 2 | Mid game | Selects best train routes |
| Multi-stop train lines | Video 2 | Mid game | Reduces deadhead by 50% |
| Cargo hub network | Video 3 | Late game | Self-optimizing cargo distribution |
| Capacity over frequency | Video 3 | All phases | 1 big train > 8 small trucks |
| Last-mile truck delivery | Video 3 | Late game | Protects hub from city congestion |
| Multi-hub scaling | Video 3 | Large maps | Infinitely scalable network |

---

## Cross-References to PRD 05_RECIPES.md

This guide ENHANCES these existing recipes:

- **Recipe 3: Ship Start** → Enhanced by Video 1 tactics (triangle loop, truck station placement)
- **Recipe 4: River Food Run** → Specific instance of Video 1 strategy
- **Recipe 9: Rail Trunk with Truck Feeders** → Foundation for Video 2's multi-stop lines
- **Recipe 14: Hub Circle Network** → VIDEO 3 COMPLETELY REDESIGNS this recipe (see PRD 05_RECIPES_UPDATE.md)

---

## When to Apply Each Video Strategy

| Game Year | Focus Video | Primary Recipe | Key Actions |
|-----------|---|---|---|
| 1850-1870 | Video 1 | Ship Start (3) | Build 1-2 triangle loops, achieve profitability |
| 1870-1890 | Video 1 → 2 | River Food (4) + Lumber (7) | Ship income funds first train |
| 1890-1910 | Video 2 | Black Gold (8), Steel (10) | Build multi-stop trains with car reuse |
| 1910-1940 | Video 2 → 3 | Steel (10), Hub prep | Establish rail network, start hub consolidation |
| 1940+ | Video 3 | Hub Circle (14) | Convert to full hub network, scale infinitely |

---

## Conclusion

These three videos provide specific, tested tactical guidance missing from the original recipes catalog. By implementing them in sequence, you scale from 1 profitable ship to a continent-spanning hub network within 100 game years.

