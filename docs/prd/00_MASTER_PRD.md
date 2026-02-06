# TF2 AI Domination System - Master PRD

## Vision

Build an autonomous multi-agent AI system that plays **Transport Fever 2** (TF2) — a transportation empire simulation game — with superhuman efficiency. The system must:

1. **Mod the game** via a Lua IPC layer that exposes game state and accepts build commands
2. **Model the game world** as a directed acyclic graph (DAG) of industries, processors, towns, and transport routes
3. **Plan and execute** supply chain construction using multi-agent coordination
4. **Learn from outcomes** to improve strategy over time
5. **Dominate** — achieve maximum town growth, transport coverage, and profit

## Game Overview

Transport Fever 2 is a real-time transportation simulation where the player builds transport networks (road, rail, ship, air) to move cargo and passengers between industries and towns. Revenue comes from delivering goods that towns demand. The game spans from 1850 to modern era with technology progression.

**Core loop:** Raw materials → Processors → Final goods → Towns (ONLY town delivery generates net revenue)

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ORCHESTRATOR (Supervisor LLM)                │
│  - Queries game state via IPC                                   │
│  - Spawns specialized agents for analysis/planning/execution    │
│  - Maintains game state DAG model                               │
│  - Stores/retrieves memory for learning                         │
│  - Loops: Observe → Plan → Execute → Verify → Learn            │
└───────────────────────────┬─────────────────────────────────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
   ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐
   │  STRATEGIST  │  │   BUILDER   │  │  VERIFIER   │
   │  - DAG model │  │  - IPC cmds │  │  - Diff chk │
   │  - Chain plan│  │  - Scaling  │  │  - Log parse│
   │  - Scoring   │  │  - Vehicles │  │  - Learning │
   └──────────────┘  └──────┬──────┘  └─────────────┘
                            │
                ┌───────────▼───────────┐
                │     IPC LAYER (Lua)    │
                │  /tmp/tf2_cmd.json     │
                │  /tmp/tf2_resp.json    │
                └───────────┬───────────┘
                            │
                ┌───────────▼───────────┐
                │   Transport Fever 2    │
                │   (Game Process)       │
                └───────────────────────┘
```

## Component PRDs

This master PRD is split into 4 detailed sub-PRDs:

| PRD | File | Scope |
|-----|------|-------|
| **01: IPC & Mod Layer** | `01_IPC_MOD_LAYER.md` | Lua mod structure, IPC protocol, all 46 command handlers, file paths, error handling |
| **02: Game Domain & DAG** | `02_GAME_DOMAIN_DAG.md` | Industry types, cargo classification, supply chain rules, DAG modeling, route scoring |
| **03: Multi-Agent System** | `03_MULTI_AGENT_SYSTEM.md` | Agent roles, orchestration loop, decision-making, memory/learning |
| **04: Operational Playbook** | `04_OPERATIONAL_PLAYBOOK.md` | Proven build sequences, scaling formulas, frequency targets, gotchas, anti-patterns |

## Key Constraints

### Technical
- TF2's Lua sandbox: no `os.execute`, no `sleep`, no network — only file I/O via `/tmp/`
- ALL JSON values must be strings (`"1855"` not `1855`) for Lua's JSON parser
- Game runs real-time at 1-4x speed; IPC polling is ~100ms
- Async operations (rail track building) require polling for completion
- Game autosaves periodically; save/load cycle takes ~5s

### Economic
- Revenue ONLY comes from delivering final goods to towns that demand them
- Feeding raw materials to processors does NOT generate net revenue (vehicle costs > transport income)
- Must complete entire chain to a town or you WILL go bankrupt
- Budget limit: never spend more than 30% of cash on a single build
- Vehicle maintenance is continuous — over-buying trucks kills profit

### Strategic
- Not all towns demand all products — MUST query `query_town_demands` before planning
- 2-stage chains (Farm→Processor→Town) are easiest to profit from
- 3+ stage chains (e.g., Steel→Goods) are much harder and riskier
- Distance matters: 1-5km routes are optimal for road, >5km consider rail
- Point-to-point routes have 50% deadhead — multi-stop loops are better

## Success Metrics

| Metric | Target |
|--------|--------|
| Cash growth | Positive YoY after year 5 |
| Line profitability | >80% of lines profitable within 3 game years |
| Town demand fulfillment | >50% of all town demands served |
| Vehicle utilization | >70% on all lines |
| Build success rate | >90% of build commands succeed |
| Chain completion rate | 100% — no incomplete chains |

## Technology Stack

- **Game Mod**: Lua (TF2's scripting API)
- **IPC Protocol**: File-based JSON over `/tmp/`
- **Agent System**: Python with async/await
- **DAG Model**: Python (networkx or custom)
- **Memory/Learning**: JSON file storage (or vector DB for semantic search)
- **LLM**: Claude, GPT-4, or similar for agent reasoning

## Getting Started

1. Read PRD 01 to understand the IPC layer and how to talk to the game
2. Read PRD 02 to understand the game domain and DAG modeling
3. Read PRD 03 to understand the multi-agent architecture
4. Read PRD 04 for proven recipes and operational knowledge
5. Start implementation: IPC layer first, then DAG, then agents
