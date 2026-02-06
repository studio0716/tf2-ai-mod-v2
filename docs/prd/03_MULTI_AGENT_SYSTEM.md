# PRD 03: Multi-Agent System

## Overview

The domination system uses a multi-agent architecture where a Supervisor orchestrates specialized agents that observe, plan, execute, verify, and learn. Each agent has a focused responsibility and communicates through structured messages.

## Agent Roles

### 1. SUPERVISOR (Orchestrator)
**Responsibility**: Top-level control loop. Decides WHAT to do and WHEN.

```
Loop forever:
  1. Query game state (year, money, speed)
  2. Spawn SURVEYOR to analyze current state
  3. Spawn STRATEGIST to rank opportunities
  4. For top-priority action:
     a. Spawn PLANNER to design build sequence
     b. Spawn BUILDER to execute build sequence
     c. Spawn VERIFIER to confirm success
     d. Spawn LEARNER to record outcome
  5. Check for problems (bankrupting lines, errors)
     - If problems found, spawn PROBLEM_SOLVER
  6. Wait for game to process, then repeat
```

**Inputs**: Game state, agent results
**Outputs**: Agent spawn decisions, memory writes

### 2. SURVEYOR (Observer)
**Responsibility**: Gathers and structures the current game state into an actionable report.

**Actions**:
- Query all industries, towns, lines, vehicles via IPC
- Build/update the DAG model
- Identify unserved town demands
- Calculate line intervals and utilization
- Detect incomplete supply chains (intermediate legs without town delivery)
- Check for bankrupt/negative-profit lines

**Output**:
```json
{
  "game_year": 1914,
  "money": 187000000,
  "total_lines": 31,
  "profitable_lines": 28,
  "unprofitable_lines": 3,
  "unserved_demands": [
    {"town": "Augusta", "cargo": "MACHINES", "demand": 32},
    {"town": "Independence", "cargo": "FUEL", "demand": 27}
  ],
  "incomplete_chains": [
    {"line_id": 33066, "cargo": "STEEL", "missing": "no town delivery"}
  ],
  "under_capacity_lines": [
    {"line_id": 46036, "interval": 267, "target": 60}
  ],
  "dag_summary": {
    "raw_producers": 15,
    "processors": 12,
    "towns": 8,
    "edges": 45,
    "unserved_edges": 12
  }
}
```

### 3. STRATEGIST (Decision Maker)
**Responsibility**: Analyzes SURVEYOR output and ranks actions by priority.

**Decision Framework**:
```
Priority 1: Fix problems (bankrupt lines, incomplete chains)
Priority 2: Complete existing partial chains to towns
Priority 3: Build new highest-ROI supply chains
Priority 4: Scale existing lines to target intervals
Priority 5: Optimize (merge lines, adjust vehicles)
```

**Scoring Factors**:
- **ROI**: Estimated return on investment (higher = better)
- **Risk**: Budget impact as % of cash (lower = better, max 30%)
- **Complexity**: Number of build steps (simpler = better)
- **Memory**: What worked/failed in similar situations before
- **Urgency**: Is money declining? Are lines losing money?

**Output**:
```json
{
  "recommended_actions": [
    {
      "action": "build_chain",
      "chain_type": "FOOD",
      "from": "Farm #3 (ID: 16700)",
      "through": "Food plant (ID: 21811)",
      "to": "Changsha (ID: 21800)",
      "estimated_cost": 2500000,
      "estimated_roi": "15% annual",
      "priority": 1,
      "reason": "2-stage chain, high demand (54), short distance (2.1km)"
    }
  ]
}
```

### 4. PLANNER (Build Designer)
**Responsibility**: Converts a strategic action into a concrete build sequence.

**For each action, produces**:
```json
{
  "name": "FOOD chain to Changsha",
  "steps": [
    {
      "step": 1,
      "name": "Build Farm to Food plant road",
      "command": "build_industry_connection",
      "params": {"industry1_id": "16700", "industry2_id": "21811"},
      "wait_seconds": 15,
      "expected_result": "new line created"
    },
    {
      "step": 2,
      "name": "Build Food plant to Changsha delivery",
      "command": "build_cargo_to_town",
      "params": {"industry_id": "21811", "town_id": "21800", "cargo": "FOOD"},
      "wait_seconds": 15,
      "expected_result": "delivery line created"
    },
    {
      "step": 3,
      "name": "Set load mode on new lines",
      "command": "set_line_load_mode",
      "params": {"line_id": "FROM_STEP_1"},
      "depends_on": [1, 2]
    },
    {
      "step": 4,
      "name": "Scale to 60s interval",
      "command": "add_vehicle_to_line",
      "params": {"line_id": "FROM_STEP_1", "count": "CALCULATED"},
      "depends_on": [3]
    }
  ]
}
```

**Planning Rules**:
- Always build feeder legs BEFORE delivery legs
- Always set load_if_available on new lines
- Always set_line_all_terminals on new lines
- Calculate vehicle count: `ceil(current_veh × current_interval / target_interval)`
- Target intervals: 60s for all lines, 30s for ore/coal feeders
- Verify town demand BEFORE planning delivery leg

### 5. BUILDER (Executor)
**Responsibility**: Executes build sequences step-by-step via IPC.

**Execution Protocol**:
```python
for step in plan.steps:
    # 1. Resolve dynamic parameters (line IDs from previous steps)
    params = resolve_params(step.params, previous_results)

    # 2. Execute command
    response = ipc.send(step.command, params)

    # 3. Wait for game to process
    await asyncio.sleep(step.wait_seconds)

    # 4. Check game logs for errors
    errors = check_stdout_for_errors()

    # 5. Record result for next steps
    previous_results[step.step] = response

    # 6. If error, stop and report
    if response.status == "error" or errors:
        return {"success": False, "failed_at": step.step, "error": errors}
```

**Vehicle Type Rules**:
- **Road (all cargos)**: Use tarp/universal trucks (`preferUniversal = true`)
- **Rail oil/crude/fuel**: Use tanker wagons
- **Rail grain/stone/ore/coal**: Use gondola wagons
- **Rail planks/tools/machines/goods/food/construction**: Use box cars
- **ALWAYS pass explicit `cargo_type`** when adding rail vehicles — auto-detection from line name picks wrong wagons

### 6. VERIFIER (Quality Checker)
**Responsibility**: Confirms builds succeeded and lines are operational.

**Verification Steps**:
```python
async def verify_build(plan, build_result):
    # 1. Query lines to find new ones
    lines = ipc.send('query_lines')
    new_lines = find_new_lines(lines, before_build_lines)

    # 2. Check each new line has vehicles
    for line in new_lines:
        if line.vehicle_count == 0:
            return {"success": False, "issue": "no vehicles on line"}

    # 3. Check intervals are reasonable (< 300s)
    for line in new_lines:
        if line.interval > 300:
            return {"needs_scaling": True, "line_id": line.id}

    # 4. Check game logs for errors
    errors = parse_stdout_for_build_errors()
    if errors:
        return {"success": False, "errors": errors}

    # 5. For rail: verify track connection
    if plan.transport_type == "rail":
        connected = ipc.send('verify_track_connection', {
            'industry1_id': plan.industry1_id,
            'industry2_id': plan.industry2_id
        })
        if connected.data.connected != "true":
            return {"success": False, "issue": "track not connected"}

    return {"success": True, "new_lines": new_lines}
```

### 7. ECONOMIST (Financial Analyst)
**Responsibility**: Monitors financial health and recommends budget decisions.

**Monitors**:
- Cash reserves (warn if < 3 months operating costs)
- Per-line profitability (flag lines losing money for >2 game years)
- Vehicle ROI (flag vehicles with negative contribution)
- Budget allocation (max 30% of cash per build action)

**Triggers**:
- `cash < 3_months_costs` → URGENT: stop building, optimize existing
- `line losing money > 2 years` → Recommend selling vehicles or deleting line
- `vehicle utilization < 50%` → Recommend reducing vehicle count

### 8. PROBLEM_SOLVER (Firefighter)
**Responsibility**: Diagnoses and fixes operational problems.

**Problem Types**:
| Problem | Diagnosis | Fix |
|---------|-----------|-----|
| Line losing money | Check: wrong cargo? No demand? Too many vehicles? | Sell excess vehicles, delete if unrecoverable |
| Incomplete chain | Check: missing final-mile to town | Build delivery leg |
| Vehicles stuck | Check: station blocked? Track disconnected? | Verify track, check terminals |
| Interval too high | Check: too few vehicles | Add vehicles to target interval |
| Build failed | Check: game logs for error | Retry or alternative approach |

### 9. LEARNER (Memory Manager)
**Responsibility**: Records outcomes and retrieves past experiences.

**What to Record**:
```python
memory.store(
    key=f"decision_{timestamp}_{action_type}",
    value={
        "action": "build_chain",
        "chain_type": "FOOD",
        "distance": 2100,
        "cost": 2500000,
        "vehicles_added": 8,
        "success": True,
        "roi_after_3_years": 0.18,
        "lessons": "2-stage food chain at 2km is reliably profitable"
    },
    tags=["supply_chain", "FOOD", "road", "success", "short_distance"],
    namespace="tf2_decisions"
)
```

**What to Search**:
```python
# Before planning a new FOOD chain:
results = memory.search(
    query="supply chain FOOD delivery to town",
    namespace="tf2_decisions",
    limit=5
)
# Returns past FOOD chain builds with outcomes
```

## Orchestration Loop

```
┌─────────────────────────────────────────────────────────────────┐
│                        SUPERVISOR LOOP                          │
│                                                                 │
│  ┌──────────┐    ┌────────────┐    ┌──────────┐               │
│  │ SURVEYOR │───►│ STRATEGIST │───►│ PLANNER  │               │
│  │ (observe)│    │  (decide)  │    │ (design) │               │
│  └──────────┘    └────────────┘    └────┬─────┘               │
│                                         │                      │
│                                    ┌────▼─────┐               │
│                                    │ BUILDER  │               │
│                                    │(execute) │               │
│                                    └────┬─────┘               │
│                                         │                      │
│                  ┌──────────┐      ┌────▼─────┐               │
│                  │ LEARNER  │◄─────│ VERIFIER │               │
│                  │ (record) │      │ (check)  │               │
│                  └──────────┘      └──────────┘               │
│                                                                 │
│  [If problems detected at any stage]                           │
│  ┌────────────────┐    ┌───────────┐                          │
│  │ PROBLEM_SOLVER │◄───│ ECONOMIST │                          │
│  │   (diagnose)   │    │ (monitor) │                          │
│  └────────────────┘    └───────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

### Timing

| Phase | Duration | Notes |
|-------|----------|-------|
| Survey | 5-10s | Query game state, build DAG |
| Strategy | 2-5s | Analyze, rank, decide |
| Planning | 2-5s | Design build sequence |
| Building | 15-60s per step | Wait for game processing |
| Verification | 5-10s | Check logs, diff state |
| Learning | 1-2s | Store outcome in memory |

### Error Handling

```python
try:
    result = await builder.execute(plan)
except BuildError as e:
    # Log failure
    learner.record_failure(plan, e)

    # Attempt recovery
    if e.type == "insufficient_funds":
        economist.recommend_cost_cutting()
    elif e.type == "build_collision":
        problem_solver.try_alternative_route(plan)
    elif e.type == "track_disconnected":
        builder.verify_and_rebuild_track(plan)
    else:
        supervisor.skip_and_continue()
```

## Communication Protocol

Agents communicate through structured message dictionaries:

```python
@dataclass
class AgentMessage:
    from_agent: str      # "SURVEYOR", "STRATEGIST", etc.
    to_agent: str        # "SUPERVISOR", "BUILDER", etc.
    message_type: str    # "state_report", "action_plan", "build_result", "error"
    payload: Dict        # Agent-specific data
    timestamp: float
    priority: int        # 0=critical, 1=high, 2=normal, 3=low
```

### Message Types

| From | To | Type | Purpose |
|------|----|------|---------|
| SURVEYOR | SUPERVISOR | state_report | Current game state analysis |
| STRATEGIST | SUPERVISOR | action_plan | Ranked list of recommended actions |
| PLANNER | SUPERVISOR | build_plan | Step-by-step build sequence |
| BUILDER | SUPERVISOR | build_result | Success/failure of build execution |
| VERIFIER | SUPERVISOR | verification | Build verification outcome |
| ECONOMIST | SUPERVISOR | financial_alert | Budget warnings |
| PROBLEM_SOLVER | SUPERVISOR | fix_result | Problem diagnosis and fix |
| LEARNER | SUPERVISOR | memory_update | What was learned |

## Memory Architecture

### Storage Layers

1. **Short-term (Session)**: Current game state, active plans, recent build results
2. **Medium-term (Persistent File)**: Decision history, outcome records, line performance
3. **Long-term (Semantic Search)**: Indexed patterns, strategy templates, learned heuristics

### Memory Schema

```python
# Decision record
{
    "key": "decision_20260205_build_food_chain",
    "namespace": "tf2_decisions",
    "tags": ["supply_chain", "FOOD", "road", "success", "2_stage"],
    "value": {
        "action_type": "build_chain",
        "chain_type": "FOOD",
        "industries": [16700, 21811],
        "town_id": 21800,
        "distance_m": 2100,
        "cost": 2500000,
        "vehicles_deployed": 8,
        "initial_interval_s": 420,
        "final_interval_s": 57,
        "success": true,
        "game_year": 1914,
        "cash_before": 108000000,
        "cash_after_3_years": 145000000,
        "lessons_learned": [
            "2-stage food chain is reliably profitable",
            "8 trucks sufficient for 2.1km route at 60s interval",
            "Set load_if_available immediately after creation"
        ]
    }
}
```

### Learning Patterns

The system should accumulate knowledge about:

1. **Chain profitability by type**: Which chains are most profitable at what distances?
2. **Vehicle scaling formulas**: How many trucks/trains per km for 60s interval?
3. **Build failure modes**: What causes builds to fail and how to avoid?
4. **Distance thresholds**: At what distance does rail beat road?
5. **Era-specific rules**: What works in 1850s vs 1920s?
6. **Map-specific knowledge**: Which industries are near which towns?

## Parallel Execution

Independent operations should run in parallel:

```python
# GOOD: Build two independent chain legs simultaneously
await asyncio.gather(
    builder.execute("build_industry_connection", {"industry1_id": "A", "industry2_id": "B"}),
    builder.execute("build_industry_connection", {"industry1_id": "C", "industry2_id": "D"})
)

# BAD: Don't parallelize dependent steps
# Step 2 (delivery to town) depends on Step 1 (feeder leg) being built first
```

### Parallelizable Operations
- Building two independent chain legs
- Querying game state while building
- Adding vehicles to different lines
- Setting load mode on multiple lines

### Sequential Operations
- Building feeder leg THEN delivery leg (same chain)
- Building road THEN adding vehicles (need line_id)
- Querying lines THEN calculating vehicle needs
