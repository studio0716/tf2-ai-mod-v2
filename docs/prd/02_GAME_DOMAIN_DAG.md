# PRD 02: Game Domain & DAG Modeling

## Overview

Transport Fever 2's economy is a directed acyclic graph (DAG) of production chains. Raw materials flow from extractors through processors to final goods delivered to towns. This PRD defines the complete domain model, cargo classification, supply chain rules, and DAG construction algorithm.

## Industry Types

### Vanilla Industries (Base Game)

#### Raw Producers (No Input Required)
| Industry | Output Cargo | Notes |
|----------|-------------|-------|
| Coal mine | COAL | Common, feeds steel mills |
| Iron ore mine | IRON_ORE | Common, feeds steel mills |
| Oil well | **CRUDE** | **NOT** `CRUDE_OIL` — the game cargo type is `CRUDE` |
| Forest | LOGS | Feeds saw mills |
| Farm | GRAIN | Feeds food processors |
| Quarry | STONE | Feeds construction material plants |

#### Processors (Require Input)
| Industry | Input(s) | Output | Delivers To |
|----------|----------|--------|-------------|
| Steel mill | IRON_ORE + COAL | STEEL | Goods/Machines/Tools factory |
| Oil refinery | **CRUDE** | **FUEL + PLASTIC** | Fuel to **TOWN**, Plastic to Goods factory |
| Saw mill | LOGS | PLANKS | Tools/Machines factory |
| Food processing plant | GRAIN | FOOD | **TOWN** |
| Construction materials plant | STONE | CONSTRUCTION_MATERIALS | **TOWN** |
| Chemical plant | PLASTIC | GOODS (with STEEL) | Goods factory |
| Goods factory | STEEL + PLASTIC | GOODS | **TOWN** |
| Machines factory | PLANKS + STEEL | MACHINES | **TOWN** |
| Tools factory | PLANKS + STEEL | TOOLS | **TOWN** |

**IMPORTANT**: The vanilla Oil refinery produces FUEL and PLASTIC directly from CRUDE. There is no separate "OIL" intermediate cargo in the vanilla game. The separate "Fuel refinery" and "Chemical plant" exist in the expanded mod with different recipes.

### Expanded Industry Mod (Workshop Mod 1950013035)

This mod adds 19 new industry types with **DIFFERENT recipes from vanilla**. Their `.con` files lack the `inputCargoTypeForAiBuilder`/`outputCargoTypeForAiBuilder` parameters that vanilla industries have, which means the game's built-in AI builder cannot discover them without backup function entries.

#### Mod Raw Producers
| Industry | Output Cargo |
|----------|-------------|
| Coffee farm | COFFEE_BERRIES |
| Fishery | FISH |
| Livestock farm | LIVESTOCK (also consumes GRAIN) |
| Marble mine | MARBLE |
| Oil sand mine | OIL_SAND |
| Silver ore mine | SILVER_ORE |

#### Mod Processors
| Industry | Input(s) | Output | Notes |
|----------|----------|--------|-------|
| Alcohol distillery | GRAIN | ALCOHOL | |
| Coffee refinery | COFFEE_BERRIES | COFFEE | |
| Meat processing plant | LIVESTOCK or FISH | MEAT | |
| Paper mill | LOGS | PAPER | |
| Silver mill | SILVER_ORE | SILVER | |
| Advanced food processing plant | MEAT or COFFEE or ALCOHOL | FOOD | **Different from vanilla!** |
| Advanced chemical plant | GRAIN | PLASTIC | **Different from vanilla!** Vanilla uses OIL |
| Advanced construction material plant | MARBLE or SLAG or SAND | CONSTRUCTION_MATERIALS | |
| Advanced fuel refinery | OIL_SAND | FUEL | **Different from vanilla!** |
| Advanced goods factory | PLASTIC + (PLANKS or PAPER or SILVER) | GOODS | **Different from vanilla!** |
| Advanced machines factory | SILVER + STEEL | MACHINES | **Different from vanilla!** |
| Advanced tools factory | STEEL | TOOLS | **Different from vanilla!** Vanilla needs PLANKS+STEEL |
| Advanced steel mill | IRON_ORE + COAL | STEEL + SLAG | Produces SLAG as byproduct |

**CRITICAL**: When both vanilla and mod industries exist on the same map, you MUST check the industry `type` field to determine which recipe applies. An `advanced_goods_factory` has completely different inputs than a regular `goods_factory`.

## Cargo Classification

### Raw Materials (From Extractors)
These cargos are produced by raw industries with no input required:
```
COAL, IRON_ORE, CRUDE, LOGS, GRAIN, STONE
COFFEE_BERRIES, FISH, MARBLE, OIL_SAND, SILVER_ORE
LIVESTOCK (special: also consumes GRAIN)
```
**Note**: The game cargo type for crude oil is `CRUDE`, not `CRUDE_OIL`.

### Intermediate Goods (Between Processors)
These cargos move between processors — they are NOT delivered to towns:
```
STEEL, PLANKS, PLASTIC, SLAG
MEAT, COFFEE, ALCOHOL, PAPER, SILVER
```

### Final Goods (To Towns)
ONLY these cargos can be delivered to towns for revenue:
```
FOOD, GOODS, FUEL, TOOLS, CONSTRUCTION_MATERIALS, MACHINES
```

### CRITICAL RULE: Cargo Type Names
- **CRUDE** (not `CRUDE_OIL`) comes from Oil wells → goes to Oil refinery
- The vanilla Oil refinery produces **FUEL** and **PLASTIC** directly from CRUDE
- There is no intermediate `OIL` cargo in vanilla — the expanded mod's fuel/chemical refineries use different recipes
- The game's internal cargo type for crude oil is `CRUDE` — using `CRUDE_OIL` in IPC commands will fail silently

## Supply Chain Rules

### Complete Chains (Must End at Town)

**FOOD chain (2 stages):**
```
Farm → [GRAIN] → Food processing plant → [FOOD] → TOWN
```

**CONSTRUCTION_MATERIALS chain (2 stages):**
```
Quarry → [STONE] → Construction materials plant → [CONSTR_MAT] → TOWN
```

**FUEL chain (2 stages, vanilla):**
```
Oil well → [CRUDE] → Oil refinery → [FUEL] → TOWN
```
Note: Vanilla oil refinery produces FUEL directly. The expanded mod has a separate fuel refinery.

**TOOLS chain (3 stages):**
```
Forest → [LOGS] → Saw mill → [PLANKS] → Tools factory → [TOOLS] → TOWN
```

**MACHINES chain (4 stages):**
```
Forest → [LOGS] → Saw mill → [PLANKS] ──┐
                                          ├→ Machines factory → [MACHINES] → TOWN
Iron mine + Coal mine → Steel mill → [STEEL] ──┘
```

**GOODS chain (5+ stages, most complex):**
```
Coal mine ──► Steel mill ──► [STEEL] ──┐
Iron mine ──►                           ├──► Goods factory → [GOODS] → TOWN
Oil well → Oil refinery → [OIL] →      │
           Chemical plant → [PLASTIC] ──┘
```

### Revenue Rule
**Revenue ONLY comes from town delivery.** Feeding raw materials to a processor (e.g., iron ore to steel mill) does NOT generate net revenue — vehicle maintenance costs EXCEED transport income on intermediate legs. You MUST complete the entire chain to a town or you WILL go bankrupt.

### Town Demand Rule
**Not all towns demand all products.** Before planning ANY delivery route, query actual demands:
```python
resp = ipc.send('query_town_demands')
# Each town has a cargo_demands dict, e.g.:
# "Indianapolis": {"FOOD": 80, "CONSTRUCTION_MATERIALS": 72}
# "Augusta": {"MACHINES": 32, "TOOLS": 37}
```
**NEVER assume a town wants a cargo — verify cargo_demands first!**

## DAG Modeling

### Data Structure

The game world is modeled as a DAG with three node types and weighted directed edges:

```python
@dataclass
class IndustryNode:
    id: int
    name: str
    type: str           # e.g., "coal_mine", "advanced_goods_factory"
    category: str       # "raw", "processor", "town"
    x: float
    y: float
    inputs: List[str]   # Cargo types consumed
    outputs: List[str]  # Cargo types produced
    input_combos: List[List[str]]  # Valid input combinations (for multi-input processors)

@dataclass
class TownNode:
    id: int
    name: str
    x: float
    y: float
    demands: Dict[str, int]  # cargo_type → demand_amount

@dataclass
class Edge:
    source_id: int
    target_id: int
    cargo: str
    distance: float     # meters
    transport_mode: str # "road", "rail", "water"
    line_id: int = None # Existing line serving this edge (None if unserved)
    score: float = 0.0
```

### DAG Construction Algorithm

```python
def build_dag(industries, towns, existing_lines):
    nodes = {}
    edges = []

    # 1. Classify all industries
    for ind in industries:
        recipe = lookup_recipe(ind.type)  # From standard + mod recipes
        node = IndustryNode(
            id=ind.id, name=ind.name, type=ind.type,
            category="raw" if not recipe.inputs else "processor",
            inputs=recipe.inputs, outputs=recipe.outputs,
            input_combos=recipe.combos
        )
        nodes[ind.id] = node

    # 2. Add town nodes
    for town in towns:
        nodes[town.id] = TownNode(id=town.id, name=town.name,
                                   demands=town.cargo_demands)

    # 3. Build edges: Raw → Processor
    for raw in [n for n in nodes.values() if n.category == "raw"]:
        for cargo in raw.outputs:
            for proc in [n for n in nodes.values() if n.category == "processor"]:
                if cargo in proc.inputs:
                    dist = distance(raw, proc)
                    if 500 <= dist <= 10000:  # Viable range
                        edges.append(Edge(raw.id, proc.id, cargo, dist))

    # 4. Build edges: Processor → Processor (intermediate goods only)
    FINAL_GOODS = {"FOOD","GOODS","FUEL","TOOLS","CONSTRUCTION_MATERIALS","MACHINES"}
    for p1 in [n for n in nodes.values() if n.category == "processor"]:
        for cargo in p1.outputs:
            if cargo in FINAL_GOODS:
                continue  # Final goods go to towns, not processors
            for p2 in [n for n in nodes.values() if n.category == "processor"]:
                if cargo in p2.inputs and p1.id != p2.id:
                    dist = distance(p1, p2)
                    if 500 <= dist <= 10000:
                        edges.append(Edge(p1.id, p2.id, cargo, dist))

    # 5. Build edges: Processor → Town (final goods only, verified demand)
    for proc in [n for n in nodes.values() if n.category == "processor"]:
        for cargo in proc.outputs:
            if cargo not in FINAL_GOODS:
                continue
            for town in [n for n in nodes.values() if isinstance(n, TownNode)]:
                if cargo in town.demands:  # MUST verify demand!
                    dist = distance(proc, town)
                    if dist <= 8000:
                        edges.append(Edge(proc.id, town.id, cargo, dist))

    # 6. Mark existing connections
    for line in existing_lines:
        # Match line stops to edges...
        pass

    return nodes, edges
```

### Chain Discovery (Backward Tracing)

Work BACKWARDS from town demands to find complete buildable chains:

```python
def discover_chains(nodes, edges, town_demands):
    chains = []

    for town_id, demands in town_demands.items():
        for cargo, demand_amount in demands.items():
            # Find processors that output this cargo
            delivery_edges = [e for e in edges
                             if e.target_id == town_id and e.cargo == cargo]

            for delivery_edge in delivery_edges:
                processor = nodes[delivery_edge.source_id]

                # Trace backward: what feeds this processor?
                chain = trace_supply_chain(processor, nodes, edges)
                chain['final_cargo'] = cargo
                chain['town'] = nodes[town_id].name
                chain['town_demand'] = demand_amount
                chain['delivery_distance'] = delivery_edge.distance
                chain['score'] = score_chain(chain)
                chains.append(chain)

    chains.sort(key=lambda c: c['score'], reverse=True)
    return chains
```

### Route Scoring Algorithm

```python
def score_chain(chain) -> float:
    if not chain['feasible']:
        return -1.0

    score = 100.0

    # Town demand bonus (higher demand = better ROI)
    score += chain['town_demand'] * 0.5

    # Distance bonus (shorter = cheaper to build and operate)
    total_dist = chain['total_distance']
    if total_dist < 3000:
        score += 30
    elif total_dist < 6000:
        score += 15
    elif total_dist < 10000:
        score += 5

    # Simplicity bonus (fewer legs = easier)
    score -= len(chain['legs']) * 5

    # Missing inputs penalty
    score -= len(chain['missing_inputs']) * 50

    # Cargo value multiplier
    CARGO_VALUE = {
        'FOOD': 1.0, 'CONSTRUCTION_MATERIALS': 1.0,
        'TOOLS': 1.2, 'FUEL': 1.1,
        'GOODS': 1.5, 'MACHINES': 1.5
    }
    score *= CARGO_VALUE.get(chain['final_cargo'], 1.0)

    return round(score, 1)
```

### Dynamic Supply Tree (Replaces Hardcoded Recipes)

**IMPORTANT**: The Python-side `STANDARD_RECIPES` dict has been replaced by the `query_supply_tree` IPC handler, which builds the complete supply chain tree server-side in Lua where all game APIs are directly accessible. This is far more accurate than parsing `.con` files or hardcoding recipes, because:

1. It uses the game's actual `constructionRep` params for OR/AND input detection
2. It falls back to backup functions in `ai_builder_new_connections_evaluation.lua` for expanded mod industries
3. It discovers live industry instances with real positions and production data
4. It handles multi-output industries (e.g., Advanced Steel Mill → STEEL + SLAG)

See **PRD 05: Dynamic Supply Tree** for the complete format and implementation details.

The `dag_builder.py` now calls `query_supply_tree` instead of using hardcoded recipes, then formats the result for the strategist.

## Distance & Transport Mode Selection

| Distance Range | Recommended Mode | Reason |
|---------------|-----------------|--------|
| 0-500m | Skip | Too close, not worth building |
| 500m-3km | Road | Cheap, fast setup, moderate truck count |
| 3-8km | Road (many trucks) or Rail | Road needs 30-90 trucks; rail may be cheaper |
| 8-15km | Rail | Road impractical (100+ trucks needed) |
| 15km+ | Rail or Ship | Only if water path available for ship |

### Truck Count Estimation
```
trucks_needed = route_distance_m / 60 * avg_truck_speed_factor

# Rough formula:
# ~1 truck per 60m of route for 60s interval
# 1km route ≈ 5-8 trucks
# 3km route ≈ 15-25 trucks
# 6km route ≈ 50-90 trucks
```

## Profitability Analysis

### Chain Profitability Ranking
1. **FOOD** (2-stage) — Easiest, low cost, quick ROI
2. **CONSTRUCTION_MATERIALS** (2-stage) — Same as FOOD, easy
3. **FUEL** (2-stage vanilla, 3-stage expanded mod) — Good value, short chain in vanilla
4. **TOOLS** (3-stage) — Moderate complexity, good value
5. **MACHINES** (4-stage) — Requires both PLANKS and STEEL
6. **GOODS** (5+ stage) — Most complex, highest value but highest risk

**Strategy**: Start with 2-stage chains ONLY (FOOD, CONSTRUCTION_MATERIALS, vanilla FUEL). Do NOT build GOODS/MACHINES until simple chains are profitable and money_rate is positive. Each vehicle costs ~$100K + ongoing maintenance — lean fleet until proven delivery.

### Break-Even Rules
- 2-stage chains break even in ~3-5 game years
- 3-stage chains break even in ~5-8 game years
- 4+ stage chains may take 10+ years — ensure sufficient cash reserves
- Keep total chain distance under 3km for road, under 10km for rail
- Don't over-buy vehicles: start with calculated amount, verify interval, adjust

## Existing Line Analysis

When the DAG is built, overlay existing transport lines to identify:
1. **Unserved edges**: Supply chain gaps that need new connections
2. **Under-capacity edges**: Lines with intervals >120s need more vehicles
3. **Incomplete chains**: Intermediate legs without final-mile town delivery (bleeding money!)
4. **Redundant lines**: Multiple lines serving the same edge (consolidate)
5. **Wrong cargo lines**: Lines delivering cargo to towns that don't demand it
