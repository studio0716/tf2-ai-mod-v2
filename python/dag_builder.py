"""
DAG Builder - Constructs a directed acyclic graph of the TF2 supply chain.

Queries the game for industries and towns, classifies them, builds edges
between compatible industries, discovers complete chains from raw producers
to towns, and scores them by profitability.

Usage:
    python dag_builder.py

    # Or programmatically:
    from dag_builder import DAGBuilder
    builder = DAGBuilder()
    dag = builder.build()
    for chain in dag['complete_chains'][:5]:
        print(f"{chain['score']}: {chain['final_cargo']} -> {chain['town']}")
"""

import math
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add parent to path for ipc_client import
sys.path.insert(0, str(Path(__file__).parent))
from ipc_client import get_ipc


# ============================================================================
# STANDARD RECIPES (Base Game)
# ============================================================================

STANDARD_RECIPES = {
    # Raw producers (no inputs)
    "coal_mine": {"inputs": [], "outputs": ["COAL"]},
    "iron_ore_mine": {"inputs": [], "outputs": ["IRON_ORE"]},
    "oil_well": {"inputs": [], "outputs": ["CRUDE_OIL"]},
    "forest": {"inputs": [], "outputs": ["LOGS"]},
    "farm": {"inputs": [], "outputs": ["GRAIN"]},
    "quarry": {"inputs": [], "outputs": ["STONE"]},

    # Processors
    "steel_mill": {"inputs": ["IRON_ORE", "COAL"], "outputs": ["STEEL"],
                   "input_rule": "all"},
    "oil_refinery": {"inputs": ["CRUDE_OIL"], "outputs": ["OIL"]},
    "saw_mill": {"inputs": ["LOGS"], "outputs": ["PLANKS"]},
    "food_processing_plant": {"inputs": ["GRAIN"], "outputs": ["FOOD"]},
    "construction_material": {"inputs": ["STONE"],
                              "outputs": ["CONSTRUCTION_MATERIALS"]},
    "chemical_plant": {"inputs": ["OIL"], "outputs": ["PLASTIC"]},
    "fuel_refinery": {"inputs": ["OIL"], "outputs": ["FUEL"]},
    "goods_factory": {"inputs": ["STEEL", "PLASTIC"], "outputs": ["GOODS"],
                      "input_rule": "all"},
    "machines_factory": {"inputs": ["PLANKS", "STEEL"], "outputs": ["MACHINES"],
                         "input_rule": "all"},
    "tools_factory": {"inputs": ["PLANKS", "STEEL"], "outputs": ["TOOLS"],
                      "input_rule": "all"},
}

# Cargos that towns can demand
TOWN_DEMANDABLE = {"FOOD", "GOODS", "FUEL", "TOOLS",
                   "CONSTRUCTION_MATERIALS", "MACHINES"}


# ============================================================================
# EXPANDED MOD RECIPE PARSING
# ============================================================================

# Path to expanded industry mod .con files (adjust for your system)
EXPANDED_MOD_DIR = Path.home() / (
    "Library/Application Support/Steam/steamapps/workshop/"
    "content/1066780/1950013035/res/construction/industry"
)


def parse_con_file(filepath: Path) -> Optional[Dict]:
    """Parse a .con file to extract industry recipe."""
    try:
        content = filepath.read_text()
    except Exception:
        return None

    # Extract stocks (input cargo types)
    stocks = re.findall(r'cargoType\s*=\s*"(\w+)"', content)

    # Extract rule outputs
    outputs = re.findall(
        r'output\s*=\s*\{[^}]*cargoType\s*=\s*"(\w+)"', content
    )

    # Extract rule input combinations
    input_match = re.search(r'input\s*=\s*\{([^}]+)\}', content)
    combos = []
    if input_match and stocks:
        for combo_match in re.finditer(r'\{([^}]+)\}', input_match.group(1)):
            try:
                flags = [int(x.strip()) for x in combo_match.group(1).split(',')]
                combo = [stocks[i] for i, flag in enumerate(flags) if flag == 1]
                if combo:
                    combos.append(combo)
            except (ValueError, IndexError):
                pass

    if not outputs:
        return None

    return {
        "inputs": stocks if combos else [],
        "outputs": outputs,
        "input_combos": combos or ([stocks] if stocks else []),
        "category": "raw" if not combos and not stocks else "processor"
    }


def load_expanded_mod_recipes() -> Dict[str, Dict]:
    """Load recipes from expanded industry mod .con files."""
    recipes = {}
    if not EXPANDED_MOD_DIR.exists():
        return recipes

    for con_file in EXPANDED_MOD_DIR.glob("*.con"):
        recipe = parse_con_file(con_file)
        if recipe:
            # Use stem as type key (e.g., "advanced_goods_factory")
            recipes[con_file.stem] = recipe

    return recipes


def load_all_recipes() -> Dict[str, Dict]:
    """Merge standard + expanded mod recipes."""
    all_recipes = dict(STANDARD_RECIPES)
    mod_recipes = load_expanded_mod_recipes()
    for rtype, recipe in mod_recipes.items():
        all_recipes[rtype] = recipe  # Mod overrides standard
    return all_recipes


# ============================================================================
# DAG BUILDER
# ============================================================================

class DAGBuilder:
    def __init__(self):
        self.ipc = get_ipc()
        self.recipes = load_all_recipes()

    def build(self) -> Dict:
        """Build the complete supply chain DAG."""
        # 1. Query game state
        game_state = self.ipc.send('query_game_state')
        industries_resp = self.ipc.send('query_industries')
        demands_resp = self.ipc.send('query_town_demands')

        if not industries_resp or not demands_resp:
            return {"error": "Could not query game state"}

        industries = industries_resp.get('data', {}).get('industries', [])
        towns_data = demands_resp.get('data', {}).get('towns', [])

        # 2. Parse town demands
        town_demands = {}
        for t in towns_data:
            demands = {}
            for demand_str in t.get('cargo_demands', '').split(', '):
                if ':' in demand_str:
                    cargo, amount = demand_str.split(':')
                    demands[cargo.strip()] = int(amount.strip())
            if demands:
                town_demands[t['id']] = {
                    'name': t.get('name', ''),
                    'x': float(t.get('x', 0)),
                    'y': float(t.get('y', 0)),
                    'demands': demands
                }

        # 3. Classify industries
        raw_producers = []
        processors = []
        unknown = []
        for ind in industries:
            classified = self._classify(ind)
            if classified['category'] == 'raw':
                raw_producers.append(classified)
            elif classified['category'] == 'processor':
                processors.append(classified)
            else:
                unknown.append(classified)

        # 4. Build edges
        edges = self._build_edges(raw_producers, processors, town_demands)

        # 5. Discover complete chains
        chains = self._discover_chains(
            raw_producers, processors, edges, town_demands
        )

        return {
            'game_state': game_state.get('data', {}) if game_state else {},
            'recipes_loaded': len(self.recipes),
            'raw_producers': raw_producers,
            'processors': processors,
            'unknown_types': unknown,
            'town_demands': town_demands,
            'edges': edges,
            'complete_chains': chains,
        }

    def _classify(self, industry: Dict) -> Dict:
        """Classify an industry using recipe database."""
        ind_type = industry.get('type', '')

        # Try exact match
        recipe = self.recipes.get(ind_type)

        # Try partial match (industry type often has prefix/suffix)
        if not recipe:
            for rtype, r in self.recipes.items():
                if rtype in ind_type or ind_type in rtype:
                    recipe = r
                    break

        if not recipe:
            return {**industry, 'category': 'unknown', 'inputs': [],
                    'outputs': [], 'input_combos': []}

        category = 'raw' if not recipe.get('inputs') else 'processor'
        return {
            **industry,
            'category': category,
            'inputs': recipe.get('inputs', []),
            'outputs': recipe.get('outputs', []),
            'input_combos': recipe.get('input_combos', [recipe.get('inputs', [])]),
        }

    def _build_edges(self, raw_producers, processors, town_demands) -> List[Dict]:
        """Build directed edges between compatible industries."""
        edges = []

        # Raw -> Processor
        for raw in raw_producers:
            for cargo in raw['outputs']:
                for proc in processors:
                    if cargo in proc['inputs']:
                        dist = self._distance(raw, proc)
                        if 500 <= dist <= 10000:
                            edges.append({
                                'source_id': raw['id'],
                                'source_name': raw.get('name', ''),
                                'target_id': proc['id'],
                                'target_name': proc.get('name', ''),
                                'cargo': cargo,
                                'distance': round(dist),
                                'type': 'raw_to_processor'
                            })

        # Processor -> Processor (intermediate goods only)
        for p1 in processors:
            for cargo in p1['outputs']:
                if cargo in TOWN_DEMANDABLE:
                    continue
                for p2 in processors:
                    if cargo in p2['inputs'] and p1['id'] != p2['id']:
                        dist = self._distance(p1, p2)
                        if 500 <= dist <= 10000:
                            edges.append({
                                'source_id': p1['id'],
                                'source_name': p1.get('name', ''),
                                'target_id': p2['id'],
                                'target_name': p2.get('name', ''),
                                'cargo': cargo,
                                'distance': round(dist),
                                'type': 'processor_to_processor'
                            })

        # Processor -> Town (final goods, verified demand)
        for proc in processors:
            for cargo in proc['outputs']:
                if cargo not in TOWN_DEMANDABLE:
                    continue
                for tid, tinfo in town_demands.items():
                    if cargo in tinfo['demands']:
                        dist = self._distance(
                            proc,
                            {'x': tinfo['x'], 'y': tinfo['y']}
                        )
                        if dist <= 8000:
                            edges.append({
                                'source_id': proc['id'],
                                'source_name': proc.get('name', ''),
                                'target_id': tid,
                                'target_name': tinfo['name'],
                                'cargo': cargo,
                                'distance': round(dist),
                                'type': 'processor_to_town',
                                'town_demand': tinfo['demands'][cargo]
                            })

        edges.sort(key=lambda e: e['distance'])
        return edges

    def _discover_chains(self, raw_producers, processors, edges,
                          town_demands) -> List[Dict]:
        """Discover complete supply chains from raw to town."""
        chains = []

        # Find all delivery edges (processor -> town)
        delivery_edges = [e for e in edges if e['type'] == 'processor_to_town']

        for delivery in delivery_edges:
            proc_id = delivery['source_id']
            proc = next((p for p in processors if str(p['id']) == str(proc_id)), None)
            if not proc:
                continue

            # Trace backward from processor
            chain = {
                'final_cargo': delivery['cargo'],
                'town': delivery['target_name'],
                'town_id': delivery['target_id'],
                'town_demand': delivery.get('town_demand', 0),
                'processor': proc.get('name', ''),
                'processor_id': proc_id,
                'delivery_distance': delivery['distance'],
                'legs': [delivery],
                'missing_inputs': [],
                'feasible': True,
                'total_distance': delivery['distance'],
            }

            # Find supply legs for each required input
            for cargo_input in proc['inputs']:
                supply = self._find_supply(
                    cargo_input, proc_id, raw_producers, processors, edges
                )
                if supply:
                    chain['legs'].extend(supply['legs'])
                    chain['total_distance'] += supply['distance']
                else:
                    chain['missing_inputs'].append(cargo_input)
                    chain['feasible'] = False

            chain['score'] = self._score_chain(chain)
            chains.append(chain)

        chains.sort(key=lambda c: c['score'], reverse=True)
        return chains

    def _find_supply(self, cargo: str, target_id, raw_producers,
                      processors, edges) -> Optional[Dict]:
        """Find a supply edge for a cargo to a target industry."""
        # Look for direct supply (raw -> target or processor -> target)
        candidates = [
            e for e in edges
            if e['cargo'] == cargo and str(e['target_id']) == str(target_id)
        ]
        if candidates:
            best = min(candidates, key=lambda e: e['distance'])
            return {'legs': [best], 'distance': best['distance']}

        # Look for indirect (raw -> intermediate_processor -> target)
        for e in edges:
            if e['cargo'] == cargo:
                return {'legs': [e], 'distance': e['distance']}

        return None

    def _score_chain(self, chain: Dict) -> float:
        """Score a chain by profitability potential."""
        if not chain['feasible']:
            return -1.0

        score = 100.0
        score += chain.get('town_demand', 0) * 0.5

        total_dist = chain['total_distance']
        if total_dist < 3000:
            score += 30
        elif total_dist < 6000:
            score += 15
        elif total_dist < 10000:
            score += 5

        score -= len(chain['legs']) * 5

        score -= len(chain['missing_inputs']) * 50

        CARGO_VALUE = {
            'FOOD': 1.0, 'CONSTRUCTION_MATERIALS': 1.0,
            'TOOLS': 1.2, 'FUEL': 1.1,
            'GOODS': 1.5, 'MACHINES': 1.5
        }
        score *= CARGO_VALUE.get(chain['final_cargo'], 1.0)

        return round(score, 1)

    @staticmethod
    def _distance(a: Dict, b: Dict) -> float:
        """Euclidean distance between two entities."""
        ax, ay = float(a.get('x', 0)), float(a.get('y', 0))
        bx, by = float(b.get('x', 0)), float(b.get('y', 0))
        return math.sqrt((ax - bx) ** 2 + (ay - by) ** 2)


# ============================================================================
# CLI
# ============================================================================

def main():
    print("=== TF2 Supply Chain DAG Builder ===\n")

    builder = DAGBuilder()
    print(f"Recipes loaded: {len(builder.recipes)}")

    dag = builder.build()

    if 'error' in dag:
        print(f"ERROR: {dag['error']}")
        return

    gs = dag['game_state']
    print(f"Game: Year {gs.get('year')}, ${int(gs.get('money', 0)):,}")
    print(f"Raw producers: {len(dag['raw_producers'])}")
    print(f"Processors: {len(dag['processors'])}")
    print(f"Unknown: {len(dag['unknown_types'])}")
    print(f"Edges: {len(dag['edges'])}")
    print(f"Town demands: {len(dag['town_demands'])}")

    print(f"\n=== Top Chains (by score) ===")
    for i, chain in enumerate(dag['complete_chains'][:10]):
        status = "OK" if chain['feasible'] else f"MISSING: {chain['missing_inputs']}"
        print(f"  {i+1}. [{chain['score']}] {chain['final_cargo']} -> "
              f"{chain['town']} (demand={chain['town_demand']}, "
              f"dist={chain['total_distance']}m) [{status}]")

    print(f"\n=== Town Demands ===")
    for tid, tinfo in dag['town_demands'].items():
        demands_str = ', '.join(f"{c}:{a}" for c, a in tinfo['demands'].items())
        print(f"  {tinfo['name']}: {demands_str}")


if __name__ == "__main__":
    main()
