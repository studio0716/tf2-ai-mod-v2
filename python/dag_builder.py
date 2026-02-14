"""
DAG Builder - Constructs a supply chain tree from live TF2 game data.

Builds the DAG dynamically backwards from town demands to suppliers,
using live industry instances plus recipes parsed from actual `.con`
files (base game construction zip + installed workshop/local mods).

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
import os
import re
import sys
import zipfile
from typing import Any, Dict, List, Optional, Tuple

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

# OR expansion can grow quickly; cap per-root variants for tractability.
MAX_CHAIN_VARIANTS_PER_ROOT = 24
# Keep nearest suppliers per OR alternative to avoid map-wide explosion.
MAX_OR_SUPPLIERS_PER_ALTERNATIVE = 1


class DAGBuilder:
    def __init__(self, strict_recipes: bool = True):
        self.ipc = get_ipc()
        self.strict_recipes = strict_recipes
        self.recipe_cache: Dict[str, Dict] = {}
        self.base_zip_path, self.construction_roots = self._discover_con_paths()
        self.last_recipe_audit: Dict[str, Any] = {}

    def build(self) -> Dict:
        """Build the complete supply chain DAG from live game data.

        Returns a dict with both the raw supply tree AND legacy flat
        chain format for backward compatibility.
        """
        # 1. Get game state
        game_state_resp = self.ipc.send('query_game_state')
        game_state = game_state_resp.get('data', {}) if game_state_resp else {}

        # 2. Build supply tree dynamically from live entities + parsed .con files
        tree, recipe_audit = self._build_supply_tree()
        self.last_recipe_audit = recipe_audit
        if not tree:
            return {"error": "Could not build supply tree", "recipe_audit": recipe_audit}

        unresolved_instances = recipe_audit.get("unresolved_instances", [])
        if self.strict_recipes and unresolved_instances:
            types = ", ".join(recipe_audit.get("unresolved_types", []))
            return {
                "error": (
                    "Recipe resolution incomplete for map industries "
                    f"(unresolved_instances={len(unresolved_instances)}; types={types})"
                ),
                "recipe_audit": recipe_audit,
            }
        towns_data = tree.get('towns', [])

        # 3. Parse tree into legacy formats
        town_demands = self._extract_town_demands(towns_data)
        raw_producers, processors = self._extract_industries(towns_data)
        edges = self._extract_edges(towns_data, town_demands)
        chains = self._extract_chains(towns_data, town_demands)
        multi_stop_candidates = self._discover_multi_stop_candidates(
            edges=edges,
            raw_producers=raw_producers,
            processors=processors,
            town_demands=town_demands,
            max_stops=4,
            min_loaded_distance_ratio=0.75,
            max_leg_distance=10000.0,
            top_k=30,
        )

        return {
            'game_state': game_state,
            'supply_tree': tree,  # New: raw tree data
            'raw_producers': raw_producers,
            'processors': processors,
            'unknown_types': [],
            'town_demands': town_demands,
            'edges': edges,
            'complete_chains': chains,
            'multi_stop_candidates': multi_stop_candidates,
            'recipe_audit': recipe_audit,
        }

    # ------------------------------------------------------------------
    # Dynamic supply tree construction
    # ------------------------------------------------------------------

    def _discover_con_paths(self) -> Tuple[str, List[str]]:
        """Discover base zip and mod construction roots."""
        home = os.path.expanduser("~")

        # Allow full override via environment variable
        game_root = os.environ.get("TF2_GAME_ROOT")
        if not game_root:
            if sys.platform == "darwin":
                game_root = os.path.join(
                    home, "Library/Application Support/Steam/steamapps/common/Transport Fever 2"
                )
            else:
                game_root = os.path.join(
                    home, ".local/share/Steam/steamapps/common/Transport Fever 2"
                )

        if sys.platform == "darwin":
            steam_apps = os.path.join(
                home, "Library/Application Support/Steam/steamapps"
            )
            # Auto-discover Steam user ID for local mods
            userdata_base = os.path.join(
                home, "Library/Application Support/Steam/userdata"
            )
        else:
            steam_apps = os.path.join(home, ".local/share/Steam/steamapps")
            userdata_base = os.path.join(home, ".local/share/Steam/userdata")

        workshop_root = os.path.join(steam_apps, "workshop/content/1066780")

        # Auto-discover Steam user ID instead of hardcoding
        local_mods_root = None
        if os.path.isdir(userdata_base):
            for uid in os.listdir(userdata_base):
                candidate = os.path.join(
                    userdata_base, uid, "1066780/local/mods"
                )
                if os.path.isdir(candidate):
                    local_mods_root = candidate
                    break

        roots: List[str] = []

        def add_mod_roots(parent: str):
            if not os.path.isdir(parent):
                return
            for entry in sorted(os.listdir(parent)):
                mod_dir = os.path.join(parent, entry)
                con_root = os.path.join(mod_dir, "res", "construction")
                if os.path.isdir(con_root):
                    roots.append(con_root)

        # Prefer overrides from workshop/local mods before base zip.
        add_mod_roots(workshop_root)
        add_mod_roots(os.path.join(game_root, "mods"))
        if local_mods_root:
            add_mod_roots(local_mods_root)

        base_zip = os.path.join(game_root, "res", "construction", "construction.zip")
        return base_zip, roots

    def _build_supply_tree(self) -> Tuple[Dict, Dict]:
        towns = self._query_town_demands()
        industries = self._query_industries_with_recipes()

        unresolved_instances = []
        for inst in industries:
            if inst.get("outputs"):
                continue
            unresolved_instances.append(
                {
                    "id": inst.get("id", ""),
                    "name": inst.get("name", ""),
                    "type": inst.get("type", ""),
                    "file_name": inst.get("file_name", ""),
                    "output_source": inst.get("output_source", ""),
                    "input_source": inst.get("input_source", ""),
                }
            )

        unresolved_types = sorted({x["type"] for x in unresolved_instances if x.get("type")})
        audit = {
            "strict_recipes": self.strict_recipes,
            "industry_instances": len(industries),
            "unresolved_instances": unresolved_instances,
            "unresolved_types": unresolved_types,
            "resolved_instances": len(industries) - len(unresolved_instances),
        }

        if not towns:
            return {"towns": []}, audit

        instances_by_cargo: Dict[str, List[Dict]] = {}
        for inst in industries:
            for cargo in inst.get("outputs", []):
                instances_by_cargo.setdefault(cargo, []).append(inst)

        town_trees = []
        for town in towns:
            supply_trees = {}
            for cargo, demand in town.get("demands", {}).items():
                roots = []
                for producer in instances_by_cargo.get(cargo, []):
                    node = self._build_supplier_node(
                        instance=producer,
                        target_x=town["x"],
                        target_y=town["y"],
                        instances_by_cargo=instances_by_cargo,
                        visited=set(),
                        depth=0,
                    )
                    if node:
                        node["distance_to_town"] = str(
                            round(self._distance_xy(producer["x"], producer["y"], town["x"], town["y"]))
                        )
                        roots.append(node)

                roots.sort(key=lambda n: int(n.get("distance_to_town", "999999")))
                if roots:
                    supply_trees[cargo] = roots

            town_trees.append(
                {
                    "id": town["id"],
                    "name": town["name"],
                    "x": str(round(town["x"])),
                    "y": str(round(town["y"])),
                    "z": str(round(town.get("z", 0.0))),
                    "demands": {k: str(v) for k, v in town.get("demands", {}).items()},
                    "supply_trees": supply_trees,
                }
            )

        town_trees.sort(key=lambda t: t["name"])
        return {"towns": town_trees}, audit

    def _query_town_demands(self) -> List[Dict]:
        resp = self.ipc.send("query_town_demands")
        if not resp or resp.get("status") != "ok":
            return []

        out = []
        for town in resp.get("data", {}).get("towns", []):
            demands = {}
            demand_str = town.get("cargo_demands", "") or ""
            for token in demand_str.split(","):
                token = token.strip()
                if not token or ":" not in token:
                    continue
                cargo, amount = token.split(":", 1)
                cargo = cargo.strip()
                amount = amount.strip()
                if not cargo:
                    continue
                try:
                    amount_i = int(float(amount))
                except ValueError:
                    continue
                if amount_i > 0:
                    demands[cargo] = amount_i

            out.append(
                {
                    "id": str(town.get("id", "")),
                    "name": town.get("name", ""),
                    "x": float(town.get("x", 0)),
                    "y": float(town.get("y", 0)),
                    "z": float(town.get("z", 0)),
                    "demands": demands,
                }
            )

        return out

    def _query_industries_with_recipes(self) -> List[Dict]:
        resp = self.ipc.send("query_industries")
        if not resp or resp.get("status") != "ok":
            return []

        industries = []
        for ind in resp.get("data", {}).get("industries", []):
            ind_id = str(ind.get("id", ""))
            detail_resp = self.ipc.send("query_industry_recipe", {"industry_id": ind_id})
            detail = detail_resp.get("data", {}) if detail_resp and detail_resp.get("status") == "ok" else {}

            file_name = detail.get("file_name") or f"industry/{ind.get('type', '')}.con"
            recipe = self._get_recipe(file_name)

            live_outputs = sorted((detail.get("items_produced") or {}).keys())
            live_inputs = sorted((detail.get("items_consumed") or {}).keys())

            outputs = live_outputs if live_outputs else recipe["outputs"]
            input_rows = self._merge_input_rows(recipe["input_rows"], live_inputs)
            input_templates = self._rows_to_input_templates(input_rows)

            if live_outputs and recipe["outputs"]:
                output_source = "live+con"
            elif live_outputs:
                output_source = "live"
            elif recipe["outputs"]:
                output_source = "con"
            else:
                output_source = "missing"

            if live_inputs and recipe["input_rows"]:
                input_source = "live+con"
            elif live_inputs:
                input_source = "live"
            elif recipe["input_rows"]:
                input_source = "con"
            else:
                input_source = "none"

            industries.append(
                {
                    "id": ind_id,
                    "name": ind.get("name", ""),
                    "type": ind.get("type", ""),
                    "file_name": file_name,
                    "x": float(ind.get("x", 0)),
                    "y": float(ind.get("y", 0)),
                    "z": float(ind.get("z", 0)),
                    "outputs": outputs,
                    "input_templates": input_templates,
                    "production_amount": self._first_production_value(detail.get("items_produced") or {}),
                    "output_source": output_source,
                    "input_source": input_source,
                }
            )

        return industries

    def _first_production_value(self, produced: Dict) -> str:
        for _, val in produced.items():
            try:
                return str(int(float(val)))
            except (TypeError, ValueError):
                continue
        return "0"

    def _merge_input_rows(self, recipe_rows: List[Dict[str, int]], live_inputs: List[str]) -> List[Dict[str, int]]:
        if recipe_rows:
            # Keep full .con recipe alternatives (including OR branches). Live
            # inputs are used only to augment unknown cargos, not to prune rows.
            if not live_inputs:
                return recipe_rows
            known_cargos = set()
            for row in recipe_rows:
                for cargo in row.keys():
                    known_cargos.add(str(cargo))
            live_only = [str(c) for c in live_inputs if str(c) and str(c) not in known_cargos]
            if not live_only:
                return recipe_rows
            augmented = list(recipe_rows)
            augmented.append({cargo: 1 for cargo in live_only})
            return augmented

        if live_inputs:
            return [{cargo: 1 for cargo in live_inputs}]

        return []

    def _rows_to_input_templates(self, rows: List[Dict[str, int]]) -> List[Dict]:
        if not rows:
            return []

        if len(rows) == 1:
            row = rows[0]
            templates = []
            for cargo in sorted(row.keys()):
                sc = max(1, int(row.get(cargo, 1)))
                templates.append(
                    {
                        "type": "and",
                        "cargo": cargo,
                        "sources_count": sc,
                    }
                )
            return templates

        # Multi-row rules are interpreted as OR alternatives among
        # non-mandatory cargos, with mandatory cargos as AND.
        present_by_row = [set(c for c, n in row.items() if n > 0) for row in rows]
        mandatory = set.intersection(*present_by_row) if present_by_row else set()
        alt_cargos = sorted(set.union(*present_by_row) - mandatory) if present_by_row else []

        templates = []
        for cargo in sorted(mandatory):
            sc = max(1, int(max(row.get(cargo, 1) for row in rows)))
            templates.append(
                {
                    "type": "and",
                    "cargo": cargo,
                    "sources_count": sc,
                }
            )

        if alt_cargos:
            templates.append(
                {
                    "type": "or",
                    "alternatives": alt_cargos,
                }
            )

        return templates

    def _build_supplier_node(
        self,
        instance: Dict,
        target_x: float,
        target_y: float,
        instances_by_cargo: Dict[str, List[Dict]],
        visited: set,
        depth: int,
    ) -> Optional[Dict]:
        if depth > 10:
            return None
        if instance["id"] in visited:
            return None

        visited.add(instance["id"])
        distance = round(self._distance_xy(instance["x"], instance["y"], target_x, target_y))

        input_groups = []
        for template in instance.get("input_templates", []):
            if template.get("type") == "and":
                cargo = template.get("cargo", "")
                suppliers = []
                for producer in instances_by_cargo.get(cargo, []):
                    if producer["id"] in visited:
                        continue
                    sub = self._build_supplier_node(
                        producer, instance["x"], instance["y"], instances_by_cargo, visited, depth + 1
                    )
                    if sub:
                        suppliers.append(sub)
                input_groups.append(
                    {
                        "type": "and",
                        "cargo": cargo,
                        "sources_count": str(template.get("sources_count", 1)),
                        "suppliers": suppliers,
                    }
                )
            elif template.get("type") == "or":
                alts = template.get("alternatives", [])
                suppliers_map = {}
                for cargo in alts:
                    cargo_suppliers = []
                    for producer in instances_by_cargo.get(cargo, []):
                        if producer["id"] in visited:
                            continue
                        sub = self._build_supplier_node(
                            producer, instance["x"], instance["y"], instances_by_cargo, visited, depth + 1
                        )
                        if sub:
                            cargo_suppliers.append(sub)
                    suppliers_map[cargo] = cargo_suppliers
                input_groups.append(
                    {
                        "type": "or",
                        "alternatives": alts,
                        "suppliers": suppliers_map,
                    }
                )

        node = {
            "producer_id": instance["id"],
            "producer_name": instance["name"],
            "producer_type": instance["type"],
            "x": str(round(instance["x"])),
            "y": str(round(instance["y"])),
            "z": str(round(instance.get("z", 0.0))),
            "distance": str(distance),
            "outputs": instance.get("outputs", []),
            "production_amount": instance.get("production_amount", "0"),
            "input_groups": input_groups,
            "is_raw": "true" if not input_groups else "false",
        }

        visited.remove(instance["id"])
        return node

    def _get_recipe(self, file_name: str) -> Dict:
        if file_name in self.recipe_cache:
            return self.recipe_cache[file_name]

        recipe = {
            "outputs": [],
            "input_rows": [],
        }

        text = self._read_con_text(file_name)
        if text:
            stocks, input_rows, outputs = self._parse_con_recipe(text)
            parsed_rows = []
            for row in input_rows:
                mapped = {}
                for idx, amount in enumerate(row):
                    if idx >= len(stocks):
                        continue
                    if amount > 0:
                        mapped[stocks[idx]] = int(amount)
                if mapped:
                    parsed_rows.append(mapped)

            recipe["outputs"] = outputs
            recipe["input_rows"] = parsed_rows

        self.recipe_cache[file_name] = recipe
        return recipe

    def _read_con_text(self, file_name: str) -> Optional[str]:
        rel = file_name
        if rel.startswith("construction/"):
            rel = rel[len("construction/"):]

        for root in self.construction_roots:
            path = os.path.join(root, rel)
            if os.path.isfile(path):
                try:
                    with open(path, "r", encoding="utf-8", errors="ignore") as f:
                        return f.read()
                except OSError:
                    continue

        if self.base_zip_path and os.path.isfile(self.base_zip_path):
            try:
                with zipfile.ZipFile(self.base_zip_path, "r") as zf:
                    if rel in zf.namelist():
                        return zf.read(rel).decode("utf-8", errors="ignore")
            except (OSError, zipfile.BadZipFile):
                return None

        return None

    def _parse_con_recipe(self, text: str) -> Tuple[List[str], List[List[int]], List[str]]:
        stock_idx = text.find("stockListConfig")
        start = stock_idx if stock_idx >= 0 else 0

        stocks_block, _ = self._extract_named_block(text, "stocks", start)
        stocks = re.findall(r'"([A-Z_0-9]+)"', stocks_block) if stocks_block else []

        rule_block, _ = self._extract_named_block(text, "rule", start)
        input_rows: List[List[int]] = []
        outputs: List[str] = []
        if rule_block:
            input_block, _ = self._extract_named_block(rule_block, "input", 0)
            output_block, _ = self._extract_named_block(rule_block, "output", 0)

            if input_block is not None:
                for row in self._extract_top_level_rows(input_block):
                    nums = [int(n) for n in re.findall(r"-?\d+", row)]
                    if nums:
                        input_rows.append(nums)

            if output_block is not None:
                outputs = sorted(set(re.findall(r"([A-Z_][A-Z0-9_]*)\s*=", output_block)))

        return stocks, input_rows, outputs

    def _extract_named_block(self, text: str, key: str, start: int) -> Tuple[Optional[str], int]:
        m = re.search(rf"\b{re.escape(key)}\s*=\s*\{{", text[start:])
        if not m:
            return None, -1
        brace_start = start + m.end() - 1
        return self._extract_brace_block(text, brace_start)

    def _extract_brace_block(self, text: str, brace_start: int) -> Tuple[Optional[str], int]:
        if brace_start < 0 or brace_start >= len(text) or text[brace_start] != "{":
            return None, -1

        depth = 0
        for idx in range(brace_start, len(text)):
            ch = text[idx]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return text[brace_start + 1:idx], idx + 1
        return None, -1

    def _extract_top_level_rows(self, block: str) -> List[str]:
        rows: List[str] = []
        i = 0
        while i < len(block):
            if block[i] == "{":
                content, end = self._extract_brace_block(block, i)
                if content is not None:
                    rows.append(content)
                    i = end
                    continue
            i += 1
        return rows

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
                    'z': float(town.get('z', 0)),
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
                'z': node.get('z', '0'),
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
                    feeder_variants = self._flatten_feeder_variants(
                        tree_node,
                        max_variants=MAX_CHAIN_VARIANTS_PER_ROOT,
                    )
                    if not feeder_variants:
                        feeder_variants = [{"legs": [], "missing_inputs": [], "branch_choices": []}]

                    seen_variant_keys = set()
                    for variant in feeder_variants:
                        feeder_legs = list(variant.get("legs", []))
                        legs = [delivery_leg] + feeder_legs
                        missing_inputs = list(variant.get("missing_inputs", []))
                        variant_key = self._chain_variant_key(legs, missing_inputs)
                        if variant_key in seen_variant_keys:
                            continue
                        seen_variant_keys.add(variant_key)

                        total_distance = delivery_dist + sum(
                            max(0, int(float(l.get('distance', 0) or 0)))
                            for l in feeder_legs
                        )
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
                            'processor_type': tree_node.get('producer_type', ''),
                            'delivery_distance': delivery_dist,
                            'legs': legs,
                            'missing_inputs': missing_inputs,
                            'feasible': feasible,
                            'total_distance': total_distance,
                            'industry_ids': list(industry_ids),
                            # New fields from tree
                            'input_groups': tree_node.get('input_groups', []),
                            'branch_choices': list(variant.get("branch_choices", [])),
                        }
                        chain['score'] = self._score_chain(chain)
                        chains.append(chain)

        chains.sort(key=lambda c: c['score'], reverse=True)
        return chains

    @staticmethod
    def _chain_variant_key(legs: List[Dict], missing_inputs: List[str]) -> Tuple:
        leg_keys = []
        for leg in legs:
            leg_keys.append(
                (
                    str(leg.get("source_id", "")),
                    str(leg.get("target_id", "")),
                    str(leg.get("cargo", "")),
                    str(leg.get("type", "")),
                    int(float(leg.get("distance", 0) or 0)),
                )
            )
        return (
            tuple(sorted(leg_keys)),
            tuple(sorted(str(m) for m in missing_inputs if str(m))),
        )

    def _flatten_feeder_variants(
        self,
        node: Dict,
        visited: Optional[set] = None,
        max_variants: int = MAX_CHAIN_VARIANTS_PER_ROOT,
    ) -> List[Dict]:
        """Expand feeder trees into variant chains, including all OR branches."""
        if visited is None:
            visited = set()

        producer_id = str(node.get("producer_id", ""))
        if producer_id and producer_id in visited:
            return [{"legs": [], "missing_inputs": [f"CYCLE:{producer_id}"], "branch_choices": []}]

        next_visited = set(visited)
        if producer_id:
            next_visited.add(producer_id)

        if node.get('is_raw') == 'true':
            return [{"legs": [], "missing_inputs": [], "branch_choices": []}]

        input_groups = node.get('input_groups', [])
        if not input_groups:
            unresolved = f"UNRESOLVED_RECIPE:{node.get('producer_type', 'unknown')}"
            return [{"legs": [], "missing_inputs": [unresolved], "branch_choices": []}]

        variants = [{"legs": [], "missing_inputs": [], "branch_choices": []}]
        for group in input_groups:
            group_variants = self._expand_input_group_variants(
                node,
                group,
                visited=next_visited,
                max_variants=max_variants,
            )
            variants = self._combine_variant_lists(
                variants,
                group_variants,
                max_variants=max_variants,
            )
            if not variants:
                break
        return self._prune_variants(variants, max_variants=max_variants)

    def _expand_input_group_variants(
        self,
        node: Dict,
        group: Dict,
        visited: set,
        max_variants: int,
    ) -> List[Dict]:
        gtype = str(group.get("type", "")).lower()
        node_id = str(node.get("producer_id", ""))
        node_name = str(node.get("producer_name", ""))

        if gtype == "and":
            cargo = str(group.get("cargo", ""))
            suppliers = group.get("suppliers", [])
            if not suppliers:
                token = cargo if cargo else "MISSING_AND_INPUT"
                return [{"legs": [], "missing_inputs": [token], "branch_choices": []}]
            best = min(
                suppliers,
                key=lambda s: int(float(s.get("distance", 999999) or 999999)),
            )
            leg = self._supplier_leg(best, node, cargo)
            sub_variants = self._flatten_feeder_variants(
                best,
                visited=visited,
                max_variants=max_variants,
            )
            out = []
            for sub in sub_variants:
                out.append(
                    {
                        "legs": [leg] + list(sub.get("legs", [])),
                        "missing_inputs": list(sub.get("missing_inputs", [])),
                        "branch_choices": list(sub.get("branch_choices", [])),
                    }
                )
            return self._prune_variants(out, max_variants=max_variants)

        if gtype == "or":
            alternatives = [str(c) for c in group.get("alternatives", []) if str(c)]
            suppliers_map = group.get("suppliers", {})
            out: List[Dict] = []

            for alt_cargo in alternatives:
                alt_suppliers = suppliers_map.get(alt_cargo, [])
                if not isinstance(alt_suppliers, list) or not alt_suppliers:
                    continue
                ordered = sorted(
                    alt_suppliers,
                    key=lambda s: int(float(s.get("distance", 999999) or 999999)),
                )
                for supplier in ordered[:max(1, MAX_OR_SUPPLIERS_PER_ALTERNATIVE)]:
                    leg = self._supplier_leg(supplier, node, alt_cargo)
                    sub_variants = self._flatten_feeder_variants(
                        supplier,
                        visited=visited,
                        max_variants=max_variants,
                    )
                    for sub in sub_variants:
                        branch_choices = list(sub.get("branch_choices", []))
                        branch_choices.insert(
                            0,
                            {
                                "group": "or",
                                "node_id": node_id,
                                "node_name": node_name,
                                "selected_cargo": alt_cargo,
                                "supplier_id": str(supplier.get("producer_id", "")),
                                "supplier_name": str(supplier.get("producer_name", "")),
                            },
                        )
                        out.append(
                            {
                                "legs": [leg] + list(sub.get("legs", [])),
                                "missing_inputs": list(sub.get("missing_inputs", [])),
                                "branch_choices": branch_choices,
                            }
                        )

            if out:
                return self._prune_variants(out, max_variants=max_variants)

            missing_token = "|".join(alternatives) if alternatives else "MISSING_OR_INPUT"
            return [{"legs": [], "missing_inputs": [missing_token], "branch_choices": []}]

        return [{"legs": [], "missing_inputs": [f"UNSUPPORTED_GROUP:{gtype or '?'}"], "branch_choices": []}]

    def _combine_variant_lists(
        self,
        left: List[Dict],
        right: List[Dict],
        max_variants: int,
    ) -> List[Dict]:
        if not left:
            return self._prune_variants(right, max_variants=max_variants)
        if not right:
            return self._prune_variants(left, max_variants=max_variants)

        combined: List[Dict] = []
        for lvar in left:
            for rvar in right:
                combined.append(
                    {
                        "legs": list(lvar.get("legs", [])) + list(rvar.get("legs", [])),
                        "missing_inputs": self._merge_missing_inputs(
                            list(lvar.get("missing_inputs", [])),
                            list(rvar.get("missing_inputs", [])),
                        ),
                        "branch_choices": list(lvar.get("branch_choices", [])) + list(rvar.get("branch_choices", [])),
                    }
                )
        return self._prune_variants(combined, max_variants=max_variants)

    @staticmethod
    def _merge_missing_inputs(left: List[str], right: List[str]) -> List[str]:
        out: List[str] = []
        seen = set()
        for token in left + right:
            tok = str(token)
            if not tok or tok in seen:
                continue
            seen.add(tok)
            out.append(tok)
        return out

    @staticmethod
    def _variant_key(variant: Dict) -> Tuple:
        legs = variant.get("legs", [])
        leg_key = tuple(
            sorted(
                (
                    str(leg.get("source_id", "")),
                    str(leg.get("target_id", "")),
                    str(leg.get("cargo", "")),
                    str(leg.get("type", "")),
                    int(float(leg.get("distance", 0) or 0)),
                )
                for leg in legs
            )
        )
        missing_key = tuple(sorted(str(x) for x in variant.get("missing_inputs", [])))
        return (leg_key, missing_key)

    @staticmethod
    def _variant_sort_key(variant: Dict) -> Tuple[int, int, int]:
        missing_count = len(variant.get("missing_inputs", []))
        total_distance = sum(
            max(0, int(float(leg.get("distance", 0) or 0)))
            for leg in variant.get("legs", [])
        )
        leg_count = len(variant.get("legs", []))
        return (missing_count, total_distance, leg_count)

    def _prune_variants(self, variants: List[Dict], max_variants: int) -> List[Dict]:
        by_key: Dict[Tuple, Dict] = {}
        for variant in variants:
            key = self._variant_key(variant)
            existing = by_key.get(key)
            if existing is None or self._variant_sort_key(variant) < self._variant_sort_key(existing):
                by_key[key] = variant
        ordered = sorted(by_key.values(), key=self._variant_sort_key)
        return ordered[:max(1, max_variants)]

    @staticmethod
    def _supplier_leg(supplier: Dict, node: Dict, cargo: str) -> Dict:
        edge_type = (
            'raw_to_processor'
            if supplier.get('is_raw') == 'true'
            else 'processor_to_processor'
        )
        return {
            'source_id': supplier.get('producer_id', ''),
            'source_name': supplier.get('producer_name', ''),
            'target_id': node.get('producer_id', ''),
            'target_name': node.get('producer_name', ''),
            'cargo': cargo,
            'distance': int(float(supplier.get('distance', 0) or 0)),
            'type': edge_type,
        }

    def _flatten_feeders(self, node: Dict, legs: List[Dict],
                         missing: List[str]):
        """Backward-compatible wrapper around variant expansion."""
        variants = self._flatten_feeder_variants(node, max_variants=1)
        if not variants:
            return
        variant = variants[0]
        legs.extend(list(variant.get("legs", [])))
        missing.extend(list(variant.get("missing_inputs", [])))

    def _flatten_feeders_legacy(self, node: Dict, legs: List[Dict],
                                missing: List[str]):
        """Legacy single-branch flattener kept for reference/debugging."""
        if node.get('is_raw') != 'true' and not node.get('input_groups'):
            unresolved = f"UNRESOLVED_RECIPE:{node.get('producer_type', 'unknown')}"
            if unresolved not in missing:
                missing.append(unresolved)
            return

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
                    self._flatten_feeders_legacy(best_supplier, legs, missing)
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
                    self._flatten_feeders_legacy(best, legs, missing)
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
    # Multi-stop candidates (truck utilization)
    # ------------------------------------------------------------------

    def _discover_multi_stop_candidates(
        self,
        edges: List[Dict],
        raw_producers: List[Dict],
        processors: List[Dict],
        town_demands: Dict[str, Dict],
        max_stops: int = 4,
        min_loaded_distance_ratio: float = 0.75,
        max_leg_distance: float = 10000.0,
        top_k: int = 30,
    ) -> List[Dict]:
        """Find triangle/square loop candidates with high loaded utilization.

        A candidate is a stop loop with 3 or 4 stops where all consecutive legs
        are loaded (directed flow edges from the DAG), and the closing leg may be
        loaded or deadhead. We rank by loaded-distance ratio, not only leg count.
        """
        if not edges:
            return []

        def as_float(v: Any, default: float = 0.0) -> float:
            try:
                return float(v)
            except (TypeError, ValueError):
                return default

        def as_int(v: Any, default: int = 0) -> int:
            try:
                return int(float(v))
            except (TypeError, ValueError):
                return default

        # Aggregate multiple cargo edges between the same directed node pair.
        pair_map: Dict[Tuple[str, str], Dict[str, Any]] = {}
        for edge in edges:
            sid = str(edge.get("source_id", ""))
            tid = str(edge.get("target_id", ""))
            if not sid or not tid or sid == tid:
                continue
            dist = as_float(edge.get("distance", 0), 0.0)
            if dist <= 0 or dist > max_leg_distance:
                continue

            key = (sid, tid)
            rec = pair_map.get(key)
            if rec is None:
                rec = {
                    "source_id": sid,
                    "target_id": tid,
                    "distance": dist,
                    "cargos": set(),
                    "flow_score": 0,
                }
                pair_map[key] = rec
            else:
                rec["distance"] = min(rec["distance"], dist)

            cargo = str(edge.get("cargo", "")).upper()
            if cargo:
                rec["cargos"].add(cargo)

            # Town legs carry explicit demand; other legs get base weight.
            rec["flow_score"] += max(1, as_int(edge.get("town_demand", 1), 1))

        adjacency: Dict[str, List[Dict[str, Any]]] = {}
        for pair in pair_map.values():
            adjacency.setdefault(pair["source_id"], []).append(pair)

        node_info = self._build_node_index(raw_producers, processors, town_demands)

        def canonical_rotation(node_ids: List[str]) -> Tuple[str, ...]:
            rots = [tuple(node_ids[i:] + node_ids[:i]) for i in range(len(node_ids))]
            return min(rots)

        candidates: List[Dict[str, Any]] = []
        seen_cycles: set = set()

        for stop_count in (3, 4):
            if stop_count > max_stops:
                continue

            def dfs(start_id: str, current_id: str, path_nodes: List[str], path_edges: List[Dict[str, Any]]):
                if len(path_nodes) == stop_count:
                    cycle_key = (stop_count, canonical_rotation(path_nodes))
                    if cycle_key in seen_cycles:
                        return
                    seen_cycles.add(cycle_key)
                    candidate = build_candidate(path_nodes, path_edges)
                    if candidate:
                        candidates.append(candidate)
                    return

                for next_edge in adjacency.get(current_id, []):
                    nid = next_edge["target_id"]
                    if nid in path_nodes:
                        continue
                    dfs(start_id, nid, path_nodes + [nid], path_edges + [next_edge])

            def build_candidate(path_nodes: List[str], path_edges: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
                if len(path_nodes) != stop_count or len(path_edges) != stop_count - 1:
                    return None

                loaded_distance = sum(e["distance"] for e in path_edges)
                flow_score = sum(e["flow_score"] for e in path_edges)

                start_id = path_nodes[0]
                end_id = path_nodes[-1]
                closing = pair_map.get((end_id, start_id))
                if closing:
                    closing_distance = closing["distance"]
                    closing_loaded = True
                    loaded_distance += closing_distance
                    flow_score += closing["flow_score"]
                else:
                    closing_loaded = False
                    a = node_info.get(end_id, {})
                    b = node_info.get(start_id, {})
                    closing_distance = self._distance_xyz(
                        as_float(a.get("x", 0), 0.0),
                        as_float(a.get("y", 0), 0.0),
                        as_float(a.get("z", 0), 0.0),
                        as_float(b.get("x", 0), 0.0),
                        as_float(b.get("y", 0), 0.0),
                        as_float(b.get("z", 0), 0.0),
                    )

                total_distance = sum(e["distance"] for e in path_edges) + closing_distance
                if total_distance <= 0:
                    return None

                loaded_legs = len(path_edges) + (1 if closing_loaded else 0)
                loaded_leg_ratio = loaded_legs / float(stop_count)
                loaded_distance_ratio = loaded_distance / float(total_distance)
                if loaded_distance_ratio < min_loaded_distance_ratio:
                    return None

                legs = []
                for edge in path_edges:
                    legs.append(
                        {
                            "source_id": edge["source_id"],
                            "source_name": node_info.get(edge["source_id"], {}).get("name", edge["source_id"]),
                            "target_id": edge["target_id"],
                            "target_name": node_info.get(edge["target_id"], {}).get("name", edge["target_id"]),
                            "distance": round(edge["distance"]),
                            "cargos": sorted(edge["cargos"]),
                            "loaded": True,
                        }
                    )

                legs.append(
                    {
                        "source_id": end_id,
                        "source_name": node_info.get(end_id, {}).get("name", end_id),
                        "target_id": start_id,
                        "target_name": node_info.get(start_id, {}).get("name", start_id),
                        "distance": round(closing_distance),
                        "cargos": sorted(closing["cargos"]) if closing else [],
                        "loaded": bool(closing_loaded),
                    }
                )

                score = (
                    loaded_distance_ratio * 100.0
                    + loaded_leg_ratio * 20.0
                    + min(30.0, flow_score / 20.0)
                    - total_distance / 3000.0
                )

                return {
                    "stop_count": stop_count,
                    "stops": [
                        {
                            "id": nid,
                            "name": node_info.get(nid, {}).get("name", nid),
                            "x": node_info.get(nid, {}).get("x", 0),
                            "y": node_info.get(nid, {}).get("y", 0),
                            "z": node_info.get(nid, {}).get("z", 0),
                        }
                        for nid in path_nodes
                    ],
                    "loaded_legs": loaded_legs,
                    "total_legs": stop_count,
                    "loaded_leg_ratio": round(loaded_leg_ratio, 3),
                    "loaded_distance_ratio": round(loaded_distance_ratio, 3),
                    "total_distance": round(total_distance),
                    "loaded_distance": round(loaded_distance),
                    "flow_score": round(flow_score, 1),
                    "score": round(score, 2),
                    "legs": legs,
                }

            for start in adjacency.keys():
                dfs(start, start, [start], [])

        candidates.sort(
            key=lambda c: (
                c.get("loaded_distance_ratio", 0.0),
                c.get("loaded_leg_ratio", 0.0),
                c.get("score", 0.0),
            ),
            reverse=True,
        )
        return candidates[:top_k]

    def _build_node_index(
        self,
        raw_producers: List[Dict],
        processors: List[Dict],
        town_demands: Dict[str, Dict],
    ) -> Dict[str, Dict[str, Any]]:
        nodes: Dict[str, Dict[str, Any]] = {}
        for arr in (raw_producers, processors):
            for node in arr:
                nid = str(node.get("id", ""))
                if not nid:
                    continue
                nodes[nid] = {
                    "id": nid,
                    "name": str(node.get("name", nid)),
                    "x": float(node.get("x", 0) or 0),
                    "y": float(node.get("y", 0) or 0),
                    "z": float(node.get("z", 0) or 0),
                }

        for tid, town in (town_demands or {}).items():
            tkey = str(tid)
            if not tkey:
                continue
            nodes[tkey] = {
                "id": tkey,
                "name": str(town.get("name", tkey)),
                "x": float(town.get("x", 0) or 0),
                "y": float(town.get("y", 0) or 0),
                "z": float(town.get("z", 0) or 0),
            }

        return nodes

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

    @staticmethod
    def _distance_xyz(
        x1: float, y1: float, z1: float,
        x2: float, y2: float, z2: float,
    ) -> float:
        """Euclidean distance between two 3D points."""
        return math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2 + (z1 - z2) ** 2)


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

    print(f"\n=== Multi-stop Truck Candidates (>=75% loaded distance) ===")
    for i, cand in enumerate(dag.get('multi_stop_candidates', [])[:10]):
        stops = " -> ".join(s['name'] for s in cand.get('stops', []))
        print(
            f"  {i+1}. [{cand.get('score')}] stops={cand.get('stop_count')} "
            f"loaded={cand.get('loaded_legs')}/{cand.get('total_legs')} "
            f"leg_ratio={cand.get('loaded_leg_ratio')} "
            f"dist_ratio={cand.get('loaded_distance_ratio')} "
            f"dist={cand.get('total_distance')}m"
        )
        print(f"       {stops}")

    print(f"\n=== Town Demands ===")
    for tid, tinfo in dag['town_demands'].items():
        demands_str = ', '.join(
            f"{c}:{a}" for c, a in tinfo['demands'].items())
        print(f"  {tinfo['name']}: {demands_str}")


if __name__ == "__main__":
    main()
