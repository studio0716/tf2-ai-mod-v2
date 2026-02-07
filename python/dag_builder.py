"""
DAG Builder - Constructs a supply chain tree from live TF2 game data.

Queries the game's Lua-side `query_supply_tree` IPC handler which uses
constructionRep params and backup functions to build a recursive tree
of all supply chains from towns back to raw materials, including OR/AND
input logic and multi-output industries.

Also converts the tree into legacy flat chain format for backward
compatibility with downstream agents (Surveyor, Strategist, Planner).

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
import sys
from typing import Dict, List

from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from ipc_client import get_ipc


# Cargos that towns can demand (kept for backward compat with surveyor import)
TOWN_DEMANDABLE = {"FOOD", "GOODS", "FUEL", "TOOLS",
                   "CONSTRUCTION_MATERIALS", "MACHINES"}

CARGO_VALUE = {
    'FOOD': 1.0, 'CONSTRUCTION_MATERIALS': 1.0,
    'TOOLS': 1.2, 'FUEL': 1.1,
    'GOODS': 1.5, 'MACHINES': 1.5,
}


class DAGBuilder:
    def __init__(self):
        self.ipc = get_ipc()

    def build(self) -> Dict:
        """Build the complete supply chain DAG from live game data.

        Returns a dict with both the raw supply tree AND legacy flat
        chain format for backward compatibility.
        """
        # 1. Get game state
        game_state_resp = self.ipc.send('query_game_state')
        game_state = game_state_resp.get('data', {}) if game_state_resp else {}

        # 2. Query the supply tree from the game (Lua-side builder)
        tree_resp = self.ipc.send('query_supply_tree')
        if not tree_resp or tree_resp.get('status') != 'ok':
            error_msg = "Could not query supply tree"
            if tree_resp:
                error_msg += f": {tree_resp.get('message', 'unknown error')}"
            return {"error": error_msg}

        tree = tree_resp.get('data', {})
        towns_data = tree.get('towns', [])

        # 3. Parse tree into legacy formats
        town_demands = self._extract_town_demands(towns_data)
        raw_producers, processors = self._extract_industries(towns_data)
        edges = self._extract_edges(towns_data, town_demands)
        chains = self._extract_chains(towns_data, town_demands)

        return {
            'game_state': game_state,
            'supply_tree': tree,  # New: raw tree data
            'raw_producers': raw_producers,
            'processors': processors,
            'unknown_types': [],
            'town_demands': town_demands,
            'edges': edges,
            'complete_chains': chains,
        }

    # ------------------------------------------------------------------
    # Legacy format extraction from tree
    # ------------------------------------------------------------------

    def _extract_town_demands(self, towns: List[Dict]) -> Dict:
        """Convert tree towns to legacy town_demands format."""
        result = {}
        for town in towns:
            demands = {}
            for cargo, amount in town.get('demands', {}).items():
                demands[cargo] = int(amount)
            if demands:
                result[town['id']] = {
                    'name': town.get('name', ''),
                    'x': float(town.get('x', 0)),
                    'y': float(town.get('y', 0)),
                    'demands': demands,
                }
        return result

    def _extract_industries(self, towns: List[Dict]):
        """Extract unique raw producers and processors from tree nodes."""
        seen_ids = set()
        raw_producers = []
        processors = []

        def walk_node(node):
            pid = node.get('producer_id', '')
            if pid in seen_ids:
                return
            seen_ids.add(pid)

            info = {
                'id': pid,
                'name': node.get('producer_name', ''),
                'type': node.get('producer_type', ''),
                'x': node.get('x', '0'),
                'y': node.get('y', '0'),
                'outputs': node.get('outputs', []),
                'production_amount': node.get('production_amount', '0'),
            }

            if node.get('is_raw') == 'true':
                info['category'] = 'raw'
                info['inputs'] = []
                raw_producers.append(info)
            else:
                info['category'] = 'processor'
                # Collect input cargos from input_groups
                inputs = []
                for group in node.get('input_groups', []):
                    if group.get('type') == 'or':
                        inputs.extend(group.get('alternatives', []))
                    elif group.get('type') == 'and':
                        cargo = group.get('cargo', '')
                        if cargo:
                            inputs.append(cargo)
                info['inputs'] = inputs
                processors.append(info)

            # Recurse into suppliers
            for group in node.get('input_groups', []):
                if group.get('type') == 'or':
                    suppliers_map = group.get('suppliers', {})
                    for cargo_key, suppliers in suppliers_map.items():
                        if isinstance(suppliers, list):
                            for s in suppliers:
                                walk_node(s)
                elif group.get('type') == 'and':
                    for s in group.get('suppliers', []):
                        walk_node(s)

        for town in towns:
            for cargo, trees in town.get('supply_trees', {}).items():
                for tree_node in trees:
                    walk_node(tree_node)

        return raw_producers, processors

    def _extract_edges(self, towns: List[Dict], town_demands: Dict) -> List[Dict]:
        """Extract edges from tree, producing legacy edge format."""
        edges = []
        seen_edges = set()

        def walk_edges(node, target_id, target_name, target_x, target_y,
                       edge_type, cargo_delivered=None):
            pid = node.get('producer_id', '')
            px = float(node.get('x', 0))
            py = float(node.get('y', 0))
            tx = float(target_x)
            ty = float(target_y)
            dist = self._distance_xy(px, py, tx, ty)

            # If cargo_delivered is specified, this is the edge cargo
            if cargo_delivered:
                edge_key = (pid, target_id, cargo_delivered)
                if edge_key not in seen_edges:
                    seen_edges.add(edge_key)
                    edge = {
                        'source_id': pid,
                        'source_name': node.get('producer_name', ''),
                        'target_id': target_id,
                        'target_name': target_name,
                        'cargo': cargo_delivered,
                        'distance': round(dist),
                        'type': edge_type,
                    }
                    if edge_type == 'processor_to_town':
                        td = town_demands.get(target_id, {})
                        edge['town_demand'] = td.get('demands', {}).get(
                            cargo_delivered, 0)
                    edges.append(edge)

            # Recurse into suppliers
            for group in node.get('input_groups', []):
                if group.get('type') == 'or':
                    suppliers_map = group.get('suppliers', {})
                    for cargo_key, suppliers in suppliers_map.items():
                        if isinstance(suppliers, list):
                            for s in suppliers:
                                s_type = ('raw_to_processor'
                                          if s.get('is_raw') == 'true'
                                          else 'processor_to_processor')
                                walk_edges(s, pid, node.get('producer_name', ''),
                                           px, py, s_type, cargo_key)
                elif group.get('type') == 'and':
                    cargo = group.get('cargo', '')
                    for s in group.get('suppliers', []):
                        s_type = ('raw_to_processor'
                                  if s.get('is_raw') == 'true'
                                  else 'processor_to_processor')
                        walk_edges(s, pid, node.get('producer_name', ''),
                                   px, py, s_type, cargo)

        for town in towns:
            tid = town['id']
            tname = town.get('name', '')
            tx = town.get('x', '0')
            ty = town.get('y', '0')
            for cargo, trees in town.get('supply_trees', {}).items():
                for tree_node in trees:
                    walk_edges(tree_node, tid, tname, tx, ty,
                               'processor_to_town', cargo)

        edges.sort(key=lambda e: e['distance'])
        return edges

    def _extract_chains(self, towns: List[Dict],
                        town_demands: Dict) -> List[Dict]:
        """Convert tree nodes into legacy flat chain format.

        Each tree node that produces a town-demanded cargo becomes a chain.
        We flatten the tree into legs (edges) for backward compat.
        """
        chains = []

        for town in towns:
            tid = town['id']
            tname = town.get('name', '')
            tx = float(town.get('x', 0))
            ty = float(town.get('y', 0))

            for cargo, trees in town.get('supply_trees', {}).items():
                demand_amount = int(town.get('demands', {}).get(cargo, 0))

                for tree_node in trees:
                    pid = tree_node.get('producer_id', '')
                    pname = tree_node.get('producer_name', '')
                    px = float(tree_node.get('x', 0))
                    py = float(tree_node.get('y', 0))
                    delivery_dist = round(self._distance_xy(px, py, tx, ty))

                    # Flatten tree into legs
                    legs = []
                    missing_inputs = []
                    total_distance = delivery_dist

                    # Delivery leg (processor -> town)
                    delivery_leg = {
                        'source_id': pid,
                        'source_name': pname,
                        'target_id': tid,
                        'target_name': tname,
                        'cargo': cargo,
                        'distance': delivery_dist,
                        'type': 'processor_to_town',
                        'town_demand': demand_amount,
                    }
                    legs.append(delivery_leg)

                    # Flatten feeder legs recursively
                    self._flatten_feeders(
                        tree_node, legs, missing_inputs)
                    total_distance += sum(
                        l['distance'] for l in legs[1:])

                    feasible = len(missing_inputs) == 0

                    # Collect all industry IDs
                    industry_ids = set()
                    for leg in legs:
                        industry_ids.add(str(leg['source_id']))
                        if leg['type'] != 'processor_to_town':
                            industry_ids.add(str(leg['target_id']))

                    chain = {
                        'final_cargo': cargo,
                        'town': tname,
                        'town_id': tid,
                        'town_demand': demand_amount,
                        'processor': pname,
                        'processor_id': pid,
                        'delivery_distance': delivery_dist,
                        'legs': legs,
                        'missing_inputs': missing_inputs,
                        'feasible': feasible,
                        'total_distance': total_distance,
                        'industry_ids': list(industry_ids),
                        # New fields from tree
                        'input_groups': tree_node.get('input_groups', []),
                    }
                    chain['score'] = self._score_chain(chain)
                    chains.append(chain)

        chains.sort(key=lambda c: c['score'], reverse=True)
        return chains

    def _flatten_feeders(self, node: Dict, legs: List[Dict],
                         missing: List[str]):
        """Recursively flatten a tree node's input groups into edge legs."""
        for group in node.get('input_groups', []):
            if group.get('type') == 'or':
                # For OR groups, pick the closest available supplier
                alternatives = group.get('alternatives', [])
                suppliers_map = group.get('suppliers', {})
                best_supplier = None
                best_cargo = None
                best_dist = float('inf')

                for alt_cargo in alternatives:
                    alt_suppliers = suppliers_map.get(alt_cargo, [])
                    if isinstance(alt_suppliers, list):
                        for s in alt_suppliers:
                            d = int(s.get('distance', 99999))
                            if d < best_dist:
                                best_dist = d
                                best_supplier = s
                                best_cargo = alt_cargo

                if best_supplier and best_cargo:
                    edge_type = ('raw_to_processor'
                                 if best_supplier.get('is_raw') == 'true'
                                 else 'processor_to_processor')
                    legs.append({
                        'source_id': best_supplier.get('producer_id', ''),
                        'source_name': best_supplier.get('producer_name', ''),
                        'target_id': node.get('producer_id', ''),
                        'target_name': node.get('producer_name', ''),
                        'cargo': best_cargo,
                        'distance': best_dist,
                        'type': edge_type,
                    })
                    self._flatten_feeders(best_supplier, legs, missing)
                else:
                    missing.append('|'.join(alternatives))

            elif group.get('type') == 'and':
                cargo = group.get('cargo', '')
                suppliers = group.get('suppliers', [])
                if suppliers:
                    # Pick closest supplier
                    best = min(suppliers,
                               key=lambda s: int(s.get('distance', 99999)))
                    edge_type = ('raw_to_processor'
                                 if best.get('is_raw') == 'true'
                                 else 'processor_to_processor')
                    legs.append({
                        'source_id': best.get('producer_id', ''),
                        'source_name': best.get('producer_name', ''),
                        'target_id': node.get('producer_id', ''),
                        'target_name': node.get('producer_name', ''),
                        'cargo': cargo,
                        'distance': int(best.get('distance', 0)),
                        'type': edge_type,
                    })
                    self._flatten_feeders(best, legs, missing)
                else:
                    missing.append(cargo)

    # ------------------------------------------------------------------
    # Scoring
    # ------------------------------------------------------------------

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
        score *= CARGO_VALUE.get(chain['final_cargo'], 1.0)

        return round(score, 1)

    # ------------------------------------------------------------------
    # Tree formatting for LLM / CLI
    # ------------------------------------------------------------------

    def format_for_llm(self, tree_data: Dict) -> str:
        """Format the supply tree as readable text for Claude LLM."""
        lines = []
        for town in tree_data.get('towns', []):
            demands_str = ', '.join(
                f"{c}:{a}" for c, a in town.get('demands', {}).items())
            lines.append(f"=== {town['name']} ({demands_str}) ===")

            for cargo, trees in town.get('supply_trees', {}).items():
                lines.append(f"  {cargo}:")
                for node in trees:
                    self._format_node(node, lines, indent=4, is_root=True)
            lines.append("")

        return '\n'.join(lines)

    def _format_node(self, node: Dict, lines: List[str], indent: int,
                     is_root: bool = False):
        """Recursively format a tree node."""
        prefix = ' ' * indent
        name = node.get('producer_name', 'Unknown')
        ptype = node.get('producer_type', '')
        dist_label = node.get('distance_to_town', node.get('distance', '?'))
        raw_tag = ' [RAW]' if node.get('is_raw') == 'true' else ''

        if is_root:
            lines.append(f"{prefix}{name} ({ptype}, {dist_label}m to town)"
                         f"{raw_tag}")
        else:
            lines.append(f"{prefix}{name} ({ptype}, {dist_label}m)"
                         f"{raw_tag}")

        for group in node.get('input_groups', []):
            if group.get('type') == 'or':
                alts = group.get('alternatives', [])
                lines.append(f"{prefix}  {'|'.join(alts)} [OR]:")
                suppliers_map = group.get('suppliers', {})
                for alt_cargo in alts:
                    suppliers = suppliers_map.get(alt_cargo, [])
                    if isinstance(suppliers, list) and suppliers:
                        lines.append(f"{prefix}    {alt_cargo}:")
                        for s in suppliers:
                            self._format_node(s, lines, indent + 6)
                    else:
                        lines.append(f"{prefix}    {alt_cargo}: [NO SUPPLIER]")
            elif group.get('type') == 'and':
                cargo = group.get('cargo', '?')
                sc = group.get('sources_count', '1')
                suppliers = group.get('suppliers', [])
                if suppliers:
                    lines.append(f"{prefix}  {cargo} [AND, need {sc}]:")
                    for s in suppliers:
                        self._format_node(s, lines, indent + 4)
                else:
                    lines.append(f"{prefix}  {cargo} [AND]: [NO SUPPLIER]")

    # ------------------------------------------------------------------
    # Utilities
    # ------------------------------------------------------------------

    @staticmethod
    def _distance(a: Dict, b: Dict) -> float:
        """Euclidean distance between two entities."""
        ax, ay = float(a.get('x', 0)), float(a.get('y', 0))
        bx, by = float(b.get('x', 0)), float(b.get('y', 0))
        return math.sqrt((ax - bx) ** 2 + (ay - by) ** 2)

    @staticmethod
    def _distance_xy(x1: float, y1: float, x2: float, y2: float) -> float:
        """Euclidean distance between two points."""
        return math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2)


# ============================================================================
# CLI
# ============================================================================

def main():
    print("=== TF2 Supply Chain DAG Builder (Dynamic) ===\n")

    builder = DAGBuilder()
    dag = builder.build()

    if 'error' in dag:
        print(f"ERROR: {dag['error']}")
        return

    gs = dag['game_state']
    print(f"Game: Year {gs.get('year')}, ${int(gs.get('money', 0)):,}")
    print(f"Raw producers: {len(dag['raw_producers'])}")
    print(f"Processors: {len(dag['processors'])}")
    print(f"Edges: {len(dag['edges'])}")
    print(f"Town demands: {len(dag['town_demands'])}")

    # Print tree view
    tree = dag.get('supply_tree', {})
    if tree:
        print(f"\n=== Supply Chain Trees ===")
        print(builder.format_for_llm(tree))

    # Print legacy chain view
    print(f"=== Top Chains (by score) ===")
    for i, chain in enumerate(dag['complete_chains'][:10]):
        status = ("OK" if chain['feasible']
                  else f"MISSING: {chain['missing_inputs']}")
        n_legs = len(chain['legs'])
        print(f"  {i+1}. [{chain['score']}] {chain['final_cargo']} -> "
              f"{chain['town']} (demand={chain['town_demand']}, "
              f"dist={chain['total_distance']}m, {n_legs} legs) [{status}]")
        for leg in chain['legs']:
            print(f"       {leg['source_name']} -> {leg['target_name']} "
                  f"({leg['cargo']}, {leg['type']}, {leg['distance']}m)")

    print(f"\n=== Town Demands ===")
    for tid, tinfo in dag['town_demands'].items():
        demands_str = ', '.join(
            f"{c}:{a}" for c, a in tinfo['demands'].items())
        print(f"  {tinfo['name']}: {demands_str}")


if __name__ == "__main__":
    main()
