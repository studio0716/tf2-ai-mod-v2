# PRD 05: Dynamic Supply Chain Tree

## Overview

The supply chain tree is built server-side in Lua via the `query_supply_tree` IPC handler. It replaces the previous approach of hardcoded `STANDARD_RECIPES` in Python, which were wrong for the expanded industry mod and couldn't handle OR/AND input logic, multi-output industries, or live instance data.

The tree walks backward from town demands through all production paths to raw materials, with full OR/AND logic, position data, and distance calculations.

## Why Server-Side

The game has all the data we need, but it's only accessible from Lua:
- **Construction rep params** (`sourcesCountForAiBuilder`) for OR/AND input detection
- **Backup functions** in `ai_builder_new_connections_evaluation.lua` with complete recipe data for ALL industry types (vanilla + expanded mod)
- **Live entity data** (`industry.itemsProduced`/`itemsConsumed`) for actual cargo types per instance
- **Entity positions** for distance calculations

Parsing `.con` files from Python was fragile, incomplete, and couldn't handle the expanded mod's recipe variations.

## Recipe Discovery

The handler discovers recipes using the same pattern as the AI builder's `discoverIndustryData()`:

1. **Primary**: Try `constructionRep` params (`inputCargoTypeForAiBuilder`, `outputCargoTypeForAiBuilder`, `sourcesCountForAiBuilder`)
2. **Fallback**: Use backup functions from `ai_builder_new_connections_evaluation.lua`:
   - `getBackupIndustriesToOutput()` — output cargos per industry type
   - `getBackupRuleSources()` — sourcesCount per input (OR/AND detection)
   - `getBackupInputsToIndustries()` — cargo → consuming industries
   - `getBackupConsumerToProducerMap()` — industry → input cargos

### OR/AND Input Detection

From `sourcesCountForAiBuilder` params:
- Value `0` = OR member (any ONE of these alternatives suffices)
- Value `>=1` = AND (this input is REQUIRED)

When multiple inputs have sourcesCount=0, they form an OR group — the industry needs any ONE of them.

**Known issue**: Some backup data has all sourcesCount=1 even for OR industries (e.g., `advanced_construction_material` with marble|stone). The handler cross-references the `hasOrCondition` flag from constructionRep discovery when available.

### Multi-Output Industries

Some industries produce multiple outputs:
- Advanced Steel Mill → STEEL + SLAG
- Oil Refinery → FUEL + PLASTIC

The tree lists ALL outputs per industry node.

## Output Format

```json
{
  "status": "ok",
  "data": {
    "towns": [
      {
        "id": "123",
        "name": "Springfield",
        "x": "100",
        "y": "200",
        "demands": {"FOOD": "80", "CONSTRUCTION_MATERIALS": "72"},
        "supply_trees": {
          "FOOD": [
            {
              "producer_id": "456",
              "producer_name": "Springfield Food Plant",
              "producer_type": "food_processing_plant",
              "x": "150",
              "y": "180",
              "distance_to_town": "500",
              "outputs": ["FOOD"],
              "production_amount": "50",
              "input_groups": [
                {
                  "type": "and",
                  "cargo": "GRAIN",
                  "sources_count": "1",
                  "suppliers": [
                    {
                      "producer_id": "789",
                      "producer_name": "West Farm",
                      "producer_type": "farm",
                      "x": "200",
                      "y": "160",
                      "distance": "72",
                      "outputs": ["GRAIN"],
                      "production_amount": "100",
                      "input_groups": [],
                      "is_raw": "true"
                    }
                  ]
                }
              ]
            }
          ],
          "CONSTRUCTION_MATERIALS": [
            {
              "producer_id": "345",
              "producer_type": "advanced_construction_material",
              "outputs": ["CONSTRUCTION_MATERIALS"],
              "input_groups": [
                {
                  "type": "or",
                  "alternatives": ["MARBLE", "STONE"],
                  "suppliers": {
                    "MARBLE": [{"producer_id": "...", "...": "..."}],
                    "STONE": [{"producer_id": "...", "...": "..."}]
                  }
                },
                {
                  "type": "and",
                  "cargo": "CEMENT",
                  "suppliers": ["..."]
                },
                {
                  "type": "and",
                  "cargo": "CLAY",
                  "suppliers": ["..."]
                }
              ]
            }
          ]
        }
      }
    ]
  }
}
```

### Key Fields

| Field | Type | Description |
|-------|------|-------------|
| `producer_id` | string | Game entity ID for the industry instance |
| `producer_type` | string | Industry fileName (e.g., `food_processing_plant`, `advanced_steel_mill`) |
| `distance_to_town` | string | Distance in meters from producer to town |
| `distance` | string | Distance in meters from supplier to consumer |
| `outputs` | array | All cargo types this industry produces |
| `production_amount` | string | Current production capacity |
| `is_raw` | string | `"true"` if raw producer (no inputs needed) |
| `input_groups` | array | Required inputs, each with type `"and"` or `"or"` |

### Input Group Types

**AND group** — this cargo is required:
```json
{
  "type": "and",
  "cargo": "GRAIN",
  "sources_count": "1",
  "suppliers": [/* recursive producer nodes */]
}
```

**OR group** — any one alternative suffices:
```json
{
  "type": "or",
  "alternatives": ["MARBLE", "STONE"],
  "suppliers": {
    "MARBLE": [/* producer nodes for MARBLE */],
    "STONE": [/* producer nodes for STONE */]
  }
}
```

## Python DAG Builder Integration

The `dag_builder.py` calls `query_supply_tree` and processes the result:

```python
class DAGBuilder:
    def build(self) -> Dict:
        resp = self.ipc.send('query_supply_tree')
        if not resp or resp.get('status') != 'ok':
            return {"error": "Could not query supply tree"}
        return resp['data']
```

It also provides:
- `format_for_llm()` — produces a readable text tree for Claude consumption
- Legacy compatibility: `complete_chains`, `town_demands`, `edges`, `raw_producers` are all still derived from the tree

### LLM-Readable Format

```
=== Springfield (FOOD:80, CONMAT:72) ===
  FOOD:
    Food Processing Plant (500m to town)
      GRAIN [AND]: West Farm (72m) [RAW]
  CONSTRUCTION_MATERIALS:
    Adv. ConMat Plant (1200m to town)
      MARBLE|STONE [OR]:
        MARBLE: Marble Mine (800m) [RAW]
        STONE: Quarry (1500m) [RAW]
      CEMENT [AND]: [NO SUPPLIER]
      CLAY [AND]: [NO SUPPLIER]
```

## Depth Limiting

- Max recursion depth of 10 to prevent infinite loops
- Tracks visited `(industryId, cargoType)` pairs to prevent cycles
- Industries that appear in their own supply chain are skipped

## Key Lua APIs Used

```lua
-- Recipe discovery
api.res.constructionRep.getAll()
api.res.constructionRep.get(id)
api.res.constructionRep.find(fileName)

-- Industry entities
game.interface.getEntities({radius=1e9}, {type="SIM_BUILDING", includeData=true})

-- Town demands
game.interface.getTownCargoSupplyAndLimit(townId)

-- Entity data
industry.itemsProduced  -- filter keys starting with _
industry.itemsConsumed  -- filter keys starting with _

-- Construction → fileName lookup
api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(entityId)
```

## Verification

To test the handler:
```python
from ipc_client import get_ipc
ipc = get_ipc()
tree = ipc.send('query_supply_tree')
import json; print(json.dumps(tree, indent=2))
```

Verify:
1. All towns appear with their demands
2. Each demanded cargo has supplier trees
3. OR groups show alternatives (e.g., MARBLE|STONE)
4. AND inputs are all listed as required
5. Multi-output industries show all outputs
6. Raw materials are leaf nodes (no further suppliers)
7. Distances and positions are included
