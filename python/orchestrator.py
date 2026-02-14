"""
TF2 orchestrator loop with pragmatic multi-agent stages.

Stages per cycle:
1. Collect metrics
2. Survey state + DAG
3. Diagnose zero-transport lines
4. Select one strategic action
5. Plan steps
6. Execute + verify
7. Persist outcome to memory
"""

import argparse
import math
import random
import re
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Set, Tuple

from dag_builder import DAGBuilder, TOWN_DEMANDABLE
from financial_guardian import FinancialGuardian
from ipc_client import get_ipc
from line_doctor import LineDoctor
from memory_store import MemoryStore
from metrics import MetricsCollector


MAX_ROAD_LEG_DISTANCE_M = 10000
ZERO_TRANSPORT_GRACE_SECONDS = 300
# Truck lines should run at ~60s interval for responsive feeder throughput.
INITIAL_TARGET_INTERVAL_SECONDS = 60
TRUCK_UTILIZATION_TARGET_MIN = 0.75
TRUCK_UTILIZATION_TARGET_HIGH = 0.80
MAX_MULTI_STOP_BUILD_LEGS = 3
ENABLE_PSEUDO_MULTI_STOP_EXECUTION = False
ROAD_MAX_LEG_DISTANCE_RECOVERY_M = 3200
ROAD_MAX_LEG_DISTANCE_NORMAL_M = 5000
ROAD_MAX_SHUNT_DISTANCE_RECOVERY_M = 3200
RAIL_MIN_LOADED_UTILIZATION = 0.70
RAIL_P2P_PROJECTED_LOADED_UTILIZATION = 0.50
RAIL_SHORT_FEEDER_MIN_DISTANCE_M = 2500
RAIL_SHORT_FEEDER_MAX_DISTANCE_M = 5000
RAIL_LONG_FEEDER_MAX_DISTANCE_M = 15000
RAIL_SHORT_FEEDER_MIN_CHAIN_DEMAND = 120
RAIL_BASE_PULL_THRESHOLD = 140
WATER_MIN_DISTANCE_M = 6000
NON_PROFITABLE_CHAIN_BUDGET_FRACTION = 0.25
MONTE_CARLO_ENABLED = True
MONTE_CARLO_MAX_CANDIDATES = 18
MONTE_CARLO_TRIALS = 200
MONTE_CARLO_HORIZON_MONTHS = 18
MONTE_CARLO_MIN_UTILIZATION_P50 = 0.70
MONTE_CARLO_MAX_DRAWDOWN_PROB = 0.40
MONTE_CARLO_MAX_CATASTROPHIC_PROB = 0.20
MONTE_CARLO_MIN_CASH_RESERVE = 20_000
MIN_BUILD_CASH_BUFFER = 150_000
MONTE_CARLO_RELAXED_UTILIZATION_P50 = 0.60
MONTE_CARLO_RELAXED_DRAWDOWN_PROB = 0.60
MONTE_CARLO_RELAXED_CATASTROPHIC_PROB = 0.30
MONTE_CARLO_SALVAGE_UTILIZATION_P50 = 0.55
MONTE_CARLO_SALVAGE_DRAWDOWN_PROB = 0.75
MONTE_CARLO_SALVAGE_CATASTROPHIC_PROB = 0.35
MONTE_CARLO_LOOKAHEAD_ENABLED = True
MONTE_CARLO_LOOKAHEAD_HORIZON_STEPS = 3
MONTE_CARLO_LOOKAHEAD_BEAM_WIDTH = 6
MONTE_CARLO_LOOKAHEAD_EXPAND_PER_NODE = 8
MONTE_CARLO_LOOKAHEAD_DISCOUNT = 0.88
MONTE_CARLO_LOOKAHEAD_STEP_MONTHS = 6
MONTE_CARLO_LOOKAHEAD_TRIALS = 60
MONTE_CARLO_LOOKAHEAD_HORIZON_MONTHS = 10
RAIL_FEEDER_ELIGIBLE_CARGOS = {
    "COAL",
    "IRON_ORE",
    "STONE",
    "CRUDE",
    "OIL",
    "OIL_SAND",
    "LOGS",
}
FINAL_GOODS = {"FOOD", "GOODS", "FUEL", "TOOLS", "CONSTRUCTION_MATERIALS", "MACHINES"}
STRATEGIC_BULK_CARGOS = {
    "COAL",
    "IRON_ORE",
    "CRUDE",
    "OIL",
    "OIL_SAND",
    "SAND",
}
SHUNT_EARLY_YEAR_MAX = 1945
TARGET_CALENDAR_SPEED = 8000
STEEL_PAYDAY_MIN_PAIR_DISTANCE_M = 2500
STEEL_PAYDAY_MAX_PAIR_DISTANCE_M = 9000
STEEL_PAYDAY_LOCAL_FEEDER_MAX_DISTANCE_M = 3200
# Do not hard-block other strategy families when steel candidates exist.
STEEL_PAYDAY_BLOCKING_MODE = False
INTERMODAL_TRANSFER_MAX_DISTANCE_M = 200
INTERMODAL_STATION_SCAN_RADIUS_M = 1200


def _to_int(value: Any, default: int = 0) -> int:
    try:
        return int(float(str(value)))
    except (TypeError, ValueError):
        return default


def _to_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return default


def _normalize_line(raw: Dict[str, Any]) -> Dict[str, Any]:
    transported = raw.get("transported", {})
    if not isinstance(transported, dict):
        transported = {}
    return {
        "id": str(raw.get("id", "")),
        "name": str(raw.get("name", "")),
        "transport_type": str(raw.get("transport_type", "unknown")).lower(),
        "vehicle_count": _to_int(raw.get("vehicle_count", 0)),
        "interval": _to_int(raw.get("interval", 0)),
        "frequency": _to_float(raw.get("frequency", 0)),
        "rate": _to_float(raw.get("rate", 0)),
        "total_transported": _to_int(raw.get("total_transported", 0)),
        "transported": transported,
    }


def _line_target_name(line_name: str) -> str:
    if "-" in line_name:
        return line_name.rsplit("-", 1)[1].strip().lower()
    return line_name.lower()


def _split_words(value: str) -> List[str]:
    return [part for part in re.split(r"[^A-Z0-9]+", str(value).upper()) if part]


def _cargo_words(cargo: str) -> List[str]:
    return _split_words(str(cargo).replace("_", " "))


def _line_suffix_has_cargo(line_name: str, cargo: str) -> bool:
    words = _split_words(line_name)
    cargo_tokens = _cargo_words(cargo)
    if not words or not cargo_tokens or len(words) < len(cargo_tokens):
        return False
    return words[-len(cargo_tokens):] == cargo_tokens


def _line_known_cargos(line: Dict[str, Any]) -> Set[str]:
    cargos = {str(c).upper() for c in line.get("transported", {}).keys()}
    for cargo in TOWN_DEMANDABLE:
        if _line_suffix_has_cargo(str(line.get("name", "")), cargo):
            cargos.add(cargo)
    return cargos


def _parse_town_demands(cargo_demands: str) -> Dict[str, int]:
    parsed: Dict[str, int] = {}
    for piece in (cargo_demands or "").split(","):
        token = piece.strip()
        if not token or ":" not in token:
            continue
        cargo, amount = token.split(":", 1)
        parsed[cargo.strip().upper()] = _to_int(amount.strip(), 0)
    return parsed


def _estimate_chain_cost(chain: Dict[str, Any]) -> int:
    """Rough conservative heuristic for budget gating."""
    legs = chain.get("legs", [])
    if not isinstance(legs, list):
        return 0
    distance = sum(max(0, _to_int(leg.get("distance", 0))) for leg in legs)
    base_per_leg = 280_000
    return int(len(legs) * base_per_leg + distance * 35)


def _estimate_multi_stop_cost(candidate: Dict[str, Any]) -> int:
    """Conservative road-build heuristic for a multi-stop loop."""
    loaded_legs = max(1, _to_int(candidate.get("loaded_legs", 0), 1))
    loaded_distance = max(0, _to_int(candidate.get("loaded_distance", 0), 0))
    base_per_leg = 280_000
    return int(loaded_legs * base_per_leg + loaded_distance * 35)


def _estimate_shunt_cost(distance: int, transport_type: str) -> int:
    d = max(0, _to_int(distance, 0))
    mode = str(transport_type or "road").lower()
    if mode == "rail":
        return int(220_000 + d * 55)
    if mode in {"water", "ship"}:
        return int(140_000 + d * 28)
    return int(85_000 + d * 22)


@dataclass
class Action:
    action: str
    priority: int
    reason: str
    payload: Dict[str, Any]


class Surveyor:
    def __init__(self, ipc, dag_builder: DAGBuilder):
        self.ipc = ipc
        self.dag_builder = dag_builder

    def run(self, dashboard: Dict[str, Any]) -> Dict[str, Any]:
        game_resp = self.ipc.send("query_game_state")
        if not game_resp or game_resp.get("status") != "ok":
            return {"ok": False, "error": "query_game_state failed"}

        lines_resp = self.ipc.send("query_lines")
        lines_raw = []
        if lines_resp and lines_resp.get("status") == "ok":
            lines_raw = lines_resp.get("data", {}).get("lines", [])
        lines = [_normalize_line(line) for line in lines_raw]

        dag = self.dag_builder.build()
        if "error" in dag:
            return {"ok": False, "error": dag["error"]}

        town_map = self._build_town_map_from_dag(dag.get("town_demands", {}))
        if not town_map:
            town_demands_resp = self.ipc.send("query_town_demands")
            towns_raw = []
            if town_demands_resp and town_demands_resp.get("status") == "ok":
                towns_raw = town_demands_resp.get("data", {}).get("towns", [])
            town_map = self._build_town_map_from_query(towns_raw)

        unserved_demands, served_pairs = self._find_unserved_demands(town_map, lines)
        incomplete_chains = [
            chain for chain in dag.get("complete_chains", [])
            if not chain.get("feasible", False)
        ]
        truck_utilization = self._truck_utilization_proxy(lines)

        return {
            "ok": True,
            "game_state": game_resp.get("data", {}),
            "money": _to_int(game_resp.get("data", {}).get("money", 0)),
            "year": _to_int(game_resp.get("data", {}).get("year", 0)),
            "lines": lines,
            "towns": town_map,
            "dag": dag,
            "dashboard": dashboard,
            "unserved_demands": unserved_demands,
            "served_pairs": served_pairs,
            "incomplete_chains": incomplete_chains,
            "truck_utilization": truck_utilization,
        }

    def _build_town_map_from_dag(
        self,
        dag_town_demands: Dict[str, Dict[str, Any]],
    ) -> Dict[str, Dict[str, Any]]:
        result = {}
        for tid, tinfo in (dag_town_demands or {}).items():
            town_id = str(tid)
            if not town_id:
                continue
            demands = {}
            for cargo, amount in (tinfo.get("demands", {}) or {}).items():
                demand = _to_int(amount, 0)
                if demand > 0:
                    demands[str(cargo).upper()] = demand
            result[town_id] = {
                "id": town_id,
                "name": str(tinfo.get("name", "")),
                "demands": demands,
            }
        return result

    def _build_town_map_from_query(
        self,
        towns_raw: List[Dict[str, Any]],
    ) -> Dict[str, Dict[str, Any]]:
        result = {}
        for town in towns_raw:
            tid = str(town.get("id", ""))
            if not tid:
                continue
            result[tid] = {
                "id": tid,
                "name": str(town.get("name", "")),
                "demands": _parse_town_demands(str(town.get("cargo_demands", ""))),
            }
        return result

    def _find_unserved_demands(
        self,
        towns: Dict[str, Dict[str, Any]],
        lines: List[Dict[str, Any]],
    ) -> Tuple[List[Dict[str, Any]], Set[Tuple[str, str]]]:
        unserved = []
        served: Set[Tuple[str, str]] = set()
        for town_id, town in towns.items():
            town_name = town.get("name", "")
            for cargo, demand in town.get("demands", {}).items():
                if demand <= 0:
                    continue
                if self._is_demand_served(lines, town_name, cargo):
                    served.add((town_id, cargo))
                else:
                    unserved.append(
                        {
                            "town_id": town_id,
                            "town": town_name,
                            "cargo": cargo,
                            "demand": demand,
                        }
                    )
        unserved.sort(key=lambda x: x["demand"], reverse=True)
        return unserved, served

    def _is_demand_served(
        self,
        lines: List[Dict[str, Any]],
        town_name: str,
        cargo: str,
    ) -> bool:
        town_lc = town_name.lower()
        cargo_uc = cargo.upper()
        for line in lines:
            target_part = _line_target_name(line.get("name", ""))
            if town_lc not in target_part:
                continue
            known_cargos = _line_known_cargos(line)
            if cargo_uc in known_cargos:
                return True
            if _line_suffix_has_cargo(str(line.get("name", "")), cargo_uc):
                return True
        return False

    def _truck_utilization_proxy(self, lines: List[Dict[str, Any]]) -> float:
        """Proxy for early cargo-road utilization from line telemetry.

        Uses the share of active cargo lines that show transported volume/rate.
        """
        cargo_lines = []
        for line in lines:
            if line.get("vehicle_count", 0) <= 0:
                continue
            if _line_known_cargos(line):
                cargo_lines.append(line)

        active = cargo_lines if cargo_lines else [
            line for line in lines if line.get("vehicle_count", 0) > 0
        ]
        if not active:
            return 0.0

        carrying = 0
        for line in active:
            if line.get("total_transported", 0) > 0 or line.get("rate", 0) > 0:
                carrying += 1
        return carrying / float(len(active))


class Diagnostician:
    def __init__(self, memory: MemoryStore):
        self.memory = memory

    def run(
        self,
        survey: Dict[str, Any],
        line_doctor: Optional["LineDoctor"] = None,
        ipc=None,
    ) -> List[Dict[str, Any]]:
        recent_line_ids: Set[str] = set()
        now = time.time()
        for record in self.memory.get_all():
            age = now - float(record.get("timestamp", 0))
            if age < ZERO_TRANSPORT_GRACE_SECONDS:
                for line_id in record.get("new_line_ids", []):
                    recent_line_ids.add(str(line_id))

        issues = []
        for line in survey.get("lines", []):
            line_id = str(line.get("id", ""))
            if line_id in recent_line_ids:
                continue
            if line.get("vehicle_count", 0) <= 0:
                continue
            if line.get("total_transported", 0) != 0:
                continue
            if line.get("rate", 0) != 0:
                continue

            issue: Dict[str, Any] = {
                "line_id": line_id,
                "line_name": line.get("name", ""),
                "root_cause_candidates": [
                    "wrong cargo config",
                    "no source supply",
                    "town does not demand cargo",
                    "route/station not connected",
                ],
            }

            # Actively fix via LineDoctor if available
            if line_doctor is not None and ipc is not None:
                fix_result = line_doctor.diagnose_and_fix(ipc, line, survey)
                issue["fix_result"] = fix_result
                issue["recommended_action"] = fix_result.get("action_taken", "waiting")
            else:
                issue["recommended_action"] = "manual_diagnose"

            issues.append(issue)
        return issues


class Strategist:
    def __init__(self, memory: MemoryStore, ipc):
        self.memory = memory
        self.ipc = ipc

    def choose_action(
        self,
        survey: Dict[str, Any],
        diagnoses: List[Dict[str, Any]],
    ) -> Optional[Action]:
        if diagnoses:
            issue = diagnoses[0]
            return Action(
                action="diagnose_line",
                priority=1,
                reason=f"Line {issue['line_id']} has zero transport with vehicles",
                payload=issue,
            )

        money = _to_int(survey.get("money", 0), 0)
        focus_cargo = self._focus_cargo_from_unserved(survey)
        if focus_cargo:
            unserved_summary = ", ".join(
                f"{r.get('town','?')}:{r.get('cargo','?')}"
                for r in survey.get("unserved_demands", [])
            )
            print(f"[strategist] focus={focus_cargo} unserved=[{unserved_summary}]")
        focus_chain_id = ""
        steel_actions: List[Action] = []
        if not focus_cargo:
            steel_actions = self._candidate_steel_payday_actions(
                survey,
                limit=max(6, MONTE_CARLO_MAX_CANDIDATES),
            )
        if steel_actions and STEEL_PAYDAY_BLOCKING_MODE:
            return self._select_action_via_rollout(survey, steel_actions)
        if money < MIN_BUILD_CASH_BUFFER and not steel_actions:
            return None

        loop_candidates: List[Dict[str, Any]] = []
        if self._should_prioritize_multi_stop(survey):
            for candidate in self._rank_multi_stop_candidates(survey):
                if not self._loop_has_input_coverage(candidate, survey):
                    continue
                loop_candidates.append(candidate)

        chain_candidates = self._rank_candidate_chains(survey)
        if focus_cargo:
            focused = [
                chain for chain in chain_candidates
                if str(chain.get("final_cargo", "")).upper() == focus_cargo
            ]
            if focused:
                chain_candidates = focused
                focus_chain_id = self._latest_target_chain_for_cargo(focus_cargo)
                if focus_chain_id:
                    locked = [
                        chain
                        for chain in chain_candidates
                        if self._chain_signature(chain) == focus_chain_id
                    ]
                    if locked:
                        chain_candidates = locked
            else:
                print(
                    f"[strategist] No {focus_cargo} chains found in DAG "
                    f"(total chains={len(chain_candidates)})"
                )
        chain_actions = self._candidate_chain_progress_actions(
            chain_candidates,
            survey,
            limit=max(10, MONTE_CARLO_MAX_CANDIDATES),
        )
        # If a previously locked chain has no immediate legal step, keep cargo
        # focus and try any other chain for that cargo before relaxing.
        if focus_cargo and not chain_actions and focus_chain_id:
            chain_candidates = [
                chain for chain in self._rank_candidate_chains(survey)
                if str(chain.get("final_cargo", "")).upper() == focus_cargo
            ]
            chain_actions = self._candidate_chain_progress_actions(
                chain_candidates,
                survey,
                limit=max(10, MONTE_CARLO_MAX_CANDIDATES),
            )
        # If focus yields no actionable move, relax focus for this
        # cycle so the orchestrator does not stall.
        if focus_cargo and not chain_actions:
            print(
                f"[strategist] No actions for {focus_cargo} chains, relaxing focus "
                f"(candidates={len(chain_candidates)})"
            )
            focus_cargo = ""
            focus_chain_id = ""
            if not steel_actions:
                steel_actions = self._candidate_steel_payday_actions(
                    survey,
                    limit=max(6, MONTE_CARLO_MAX_CANDIDATES),
                )
            chain_candidates = self._rank_candidate_chains(survey)
            chain_actions = self._candidate_chain_progress_actions(
                chain_candidates,
                survey,
                limit=max(10, MONTE_CARLO_MAX_CANDIDATES),
            )

        candidate_actions: List[Action] = []
        candidate_actions.extend(steel_actions)
        candidate_actions.extend(
            self._candidate_loop_actions(loop_candidates, survey, limit=3)
        )
        candidate_actions.extend(chain_actions)
        if not candidate_actions:
            print(
                f"[strategist] WARNING: zero candidate actions "
                f"(steel={len(steel_actions)}, loops={len(loop_candidates)}, "
                f"chains={len(chain_actions)})"
            )
        # Only consider raw-precursor bridge actions when no chain can be
        # advanced directly. This prevents over-focusing on raw feeders.
        if (not focus_cargo) and (not any(action.action == "build_chain" for action in chain_actions)):
            candidate_actions.extend(
                self._candidate_recipe_bridge_actions(
                    survey,
                    limit=6,
                )
            )

        mc_action = self._select_action_via_rollout(survey, candidate_actions)
        return mc_action

    def _focus_cargo_from_unserved(self, survey: Dict[str, Any]) -> str:
        # Prioritize simpler chains first — they're cheaper and ROI faster.
        # Only focus on cargo types that actually have viable chains in the DAG.
        unserved = survey.get("unserved_demands", [])
        if not unserved:
            return ""
        # Priority order: simplest chains first (fewest supply chain legs)
        priority = [
            "FOOD",                     # 2 legs
            "CONSTRUCTION_MATERIALS",   # 2-3 legs
            "FUEL",                     # 2-3 legs
            "TOOLS",                    # 3-4 legs
            "GOODS",                    # 5-7 legs
            "MACHINES",                 # 7+ legs
        ]
        unserved_cargos = {
            str(rec.get("cargo", "")).upper() for rec in unserved
        }
        # Check which cargo types have viable chains in the DAG
        all_chains = survey.get("dag", {}).get("complete_chains", [])
        served_pairs = survey.get("served_pairs", set())
        viable_cargos: set = set()
        for chain in all_chains:
            if not chain.get("feasible", False):
                continue
            cargo = str(chain.get("final_cargo", "")).upper()
            town_id = str(chain.get("town_id", ""))
            if (town_id, cargo) not in served_pairs:
                viable_cargos.add(cargo)
        for cargo in priority:
            if cargo in unserved_cargos and cargo in viable_cargos:
                return cargo
        # No viable focused cargo — return empty to allow general actions
        return ""

    def _latest_target_chain_for_cargo(self, cargo: str) -> str:
        target_cargo = str(cargo or "").upper()
        if not target_cargo:
            return ""
        for rec in reversed(self.memory.get_all()):
            if rec.get("simulated", False):
                continue
            if not rec.get("success", False):
                continue
            target_chain_id = str(rec.get("target_chain_id", ""))
            if not target_chain_id:
                continue
            rec_cargo = str(rec.get("target_chain_cargo", "")).upper()
            if not rec_cargo:
                rec_cargo = str(rec.get("cargo", "")).upper()
            if rec_cargo != target_cargo:
                continue
            return target_chain_id
        return ""

    def _candidate_chain_progress_actions(
        self,
        chain_candidates: List[Dict[str, Any]],
        survey: Dict[str, Any],
        limit: int = 12,
    ) -> List[Action]:
        required_inputs = self._required_and_inputs_by_processor(survey)
        processor_names = self._processor_name_by_id(survey)
        processor_chain_demand = self._processor_chain_demand_by_id(survey)
        node_pos = self._node_position_index(survey.get("dag", {}))
        edge_pull = self._edge_chain_pull(survey.get("dag", {}).get("complete_chains", []))
        non_profitable = self._is_non_profitable(survey)

        ranked_actions: List[Tuple[float, Action]] = []
        seen_shunt_signatures: Set[str] = set()
        for chain in chain_candidates:
            planning = self._chain_planning_directives(chain, survey)
            town_id = str(chain.get("town_id", ""))
            cargo = str(chain.get("final_cargo", "")).upper()
            chain_id = self._chain_signature(chain)
            missing = self._missing_feeder_legs_for_chain(
                chain,
                survey,
                required_inputs,
                processor_names,
            )
            profitability = self._chain_profitability_proxy(chain, len(missing))

            if missing:
                chosen_leg: Optional[Dict[str, Any]] = None
                chosen_candidate: Optional[Dict[str, Any]] = None
                shunt_signature = ""
                shunt_pair_signature = ""
                for leg in missing:
                    candidate = self._leg_to_shunt_candidate(
                        leg,
                        chain,
                        node_pos=node_pos,
                        edge_pull=edge_pull,
                        non_profitable=non_profitable,
                    )
                    if not candidate:
                        continue
                    if not self._is_strategic_shunt_candidate(
                        candidate,
                        survey,
                        required_inputs,
                        processor_names,
                        processor_chain_demand,
                    ):
                        continue
                    sig = self._shunt_signature(candidate)
                    pair_sig = self._shunt_pair_signature(candidate)
                    if sig in seen_shunt_signatures:
                        continue
                    if self._has_recent_signature_success(sig):
                        continue
                    chosen_leg = leg
                    chosen_candidate = candidate
                    shunt_signature = sig
                    shunt_pair_signature = pair_sig
                    break
                if chosen_leg and chosen_candidate:
                    seen_shunt_signatures.add(shunt_signature)
                    reason = (
                        f"DAG prerequisite for {cargo} -> {chain.get('town', '?')}: "
                        f"{chosen_candidate.get('source_name', '?')} -> {chosen_candidate.get('target_name', '?')} "
                        f"({chosen_candidate.get('cargo', '?')}, step {len(missing)})"
                    )
                    action = Action(
                        action="build_shunt",
                        priority=2,
                        reason=reason,
                        payload={
                            "candidate": chosen_candidate,
                            "shunt_signature": shunt_signature,
                            "shunt_pair_signature": shunt_pair_signature,
                            "target_chain_id": chain_id,
                            "target_chain_cargo": cargo,
                        },
                    )
                    score = profitability + (8.0 if str(chosen_leg.get("type", "")) == "raw_to_processor" else 0.0)
                    ranked_actions.append((score, action))
                    continue
                # All missing feeders failed checks — try delivery leg anyway.
                # Processors may have partial supply from other connections.
                print(
                    f"[strategist] {cargo} -> {chain.get('town', '?')}: "
                    f"{len(missing)} feeders unbuildable, attempting delivery leg"
                )

            if self.memory.has_recent_success(cargo=cargo, town_id=town_id):
                continue
            action = Action(
                action="build_chain",
                priority=3,
                reason=(
                    f"DAG-ready chain {cargo} -> {chain.get('town', '?')} "
                    f"(score={chain.get('score')}, rail_feeder={planning.get('allow_rail_feeder_exception')})"
                ),
                payload={
                    "chain": chain,
                    "planning": planning,
                    "target_chain_id": chain_id,
                },
            )
            ranked_actions.append((profitability, action))

        ranked_actions.sort(key=lambda row: row[0], reverse=True)
        return [row[1] for row in ranked_actions[: max(1, limit)]]

    def _candidate_steel_payday_actions(
        self,
        survey: Dict[str, Any],
        limit: int = 6,
    ) -> List[Action]:
        dag = survey.get("dag", {}) or {}
        edges = dag.get("edges", []) or []
        if not edges:
            return []

        required_inputs = self._required_and_inputs_by_processor(survey)
        processor_names = self._processor_name_by_id(survey)
        processor_chain_demand = self._processor_chain_demand_by_id(survey)
        node_pos = self._node_position_index(dag)
        node_types = self._node_type_by_id(dag)
        edge_pull = self._edge_chain_pull(dag.get("complete_chains", []))
        non_profitable = self._is_non_profitable(survey)

        steel_nodes = [
            node for node in dag.get("processors", [])
            if "steel_mill" in str(node.get("type", "")).lower()
        ]
        if len(steel_nodes) < 2:
            return []

        incoming: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
        for edge in edges:
            if str(edge.get("type", "")) != "raw_to_processor":
                continue
            cargo = str(edge.get("cargo", "")).upper()
            if cargo not in {"COAL", "IRON_ORE"}:
                continue
            target_id = str(edge.get("target_id", ""))
            if not target_id:
                continue
            incoming.setdefault((target_id, cargo), []).append(edge)
        for bucket in incoming.values():
            bucket.sort(key=lambda e: _to_int(e.get("distance", 0), 0))

        steel_by_id = {str(n.get("id", "")): n for n in steel_nodes if str(n.get("id", ""))}
        steel_ids = sorted(steel_by_id.keys())
        ranked_actions: List[Tuple[int, float, Action]] = []
        seen_shunt_signatures: Set[str] = set()
        existing_line_ids = {
            str(line.get("id", ""))
            for line in survey.get("lines", [])
            if str(line.get("id", ""))
        }

        for i, mill_a in enumerate(steel_ids):
            for mill_b in steel_ids[i + 1:]:
                pair_distance = self._node_distance(node_pos, mill_a, mill_b)
                if pair_distance <= 0:
                    continue
                if pair_distance < STEEL_PAYDAY_MIN_PAIR_DISTANCE_M:
                    continue
                if pair_distance > STEEL_PAYDAY_MAX_PAIR_DISTANCE_M:
                    continue

                ore_to_a = self._best_edge(incoming, mill_a, "IRON_ORE")
                coal_to_a = self._best_edge(incoming, mill_a, "COAL")
                ore_to_b = self._best_edge(incoming, mill_b, "IRON_ORE")
                coal_to_b = self._best_edge(incoming, mill_b, "COAL")

                options: List[Tuple[float, str, str, Dict[str, Any], Dict[str, Any]]] = []
                if ore_to_a and coal_to_b:
                    options.append((
                        _to_int(ore_to_a.get("distance", 0), 0) + _to_int(coal_to_b.get("distance", 0), 0),
                        mill_a,
                        mill_b,
                        ore_to_a,
                        coal_to_b,
                    ))
                if ore_to_b and coal_to_a:
                    options.append((
                        _to_int(ore_to_b.get("distance", 0), 0) + _to_int(coal_to_a.get("distance", 0), 0),
                        mill_b,
                        mill_a,
                        ore_to_b,
                        coal_to_a,
                    ))
                if not options:
                    continue

                options.sort(key=lambda row: row[0])
                _, ore_mill, coal_mill, ore_local, coal_local = options[0]
                if _to_int(ore_local.get("distance", 0), 0) > STEEL_PAYDAY_LOCAL_FEEDER_MAX_DISTANCE_M:
                    continue
                if _to_int(coal_local.get("distance", 0), 0) > STEEL_PAYDAY_LOCAL_FEEDER_MAX_DISTANCE_M:
                    continue

                pair_pull = max(
                    120,
                    _to_int(processor_chain_demand.get(ore_mill, 0), 0),
                    _to_int(processor_chain_demand.get(coal_mill, 0), 0),
                )
                pair_pull += 90
                exchange_mode = self._select_shunt_transport(
                    coal_mill,
                    ore_mill,
                    pair_distance,
                    pair_pull,
                    node_pos,
                    non_profitable=non_profitable,
                )
                if exchange_mode not in {"rail", "water"}:
                    continue

                ore_mill_name = str(steel_by_id.get(ore_mill, {}).get("name", ore_mill))
                coal_mill_name = str(steel_by_id.get(coal_mill, {}).get("name", coal_mill))

                ordered_legs = [
                    {
                        "phase": "local_ore",
                        "source_id": str(ore_local.get("source_id", "")),
                        "source_name": str(ore_local.get("source_name", "")),
                        "target_id": ore_mill,
                        "target_name": ore_mill_name,
                        "cargo": "IRON_ORE",
                        "type": "raw_to_processor",
                        "distance": _to_int(ore_local.get("distance", 0), 0),
                        "preferred_transport": "road",
                    },
                    {
                        "phase": "local_coal",
                        "source_id": str(coal_local.get("source_id", "")),
                        "source_name": str(coal_local.get("source_name", "")),
                        "target_id": coal_mill,
                        "target_name": coal_mill_name,
                        "cargo": "COAL",
                        "type": "raw_to_processor",
                        "distance": _to_int(coal_local.get("distance", 0), 0),
                        "preferred_transport": "road",
                    },
                    {
                        "phase": "exchange_coal",
                        "source_id": coal_mill,
                        "source_name": coal_mill_name,
                        "target_id": ore_mill,
                        "target_name": ore_mill_name,
                        "cargo": "COAL",
                        "type": "processor_to_processor",
                        "distance": pair_distance,
                        "preferred_transport": exchange_mode,
                    },
                ]

                pair_sig = f"steel-payday:{ore_mill}>{coal_mill}"
                next_idx = -1
                for idx, leg in enumerate(ordered_legs):
                    phase = str(leg.get("phase", ""))
                    served_live = self._is_leg_served(survey, leg)
                    served_memory = self._has_successful_strategy_phase(
                        "steel_payday",
                        pair_sig,
                        phase,
                        existing_line_ids,
                    )
                    if not (served_live or served_memory):
                        next_idx = idx
                        break
                if next_idx < 0:
                    continue
                chosen_leg = ordered_legs[next_idx]
                pseudo_chain = {"town_demand": pair_pull, "_effective_score": 70.0}
                chosen_candidate = self._leg_to_shunt_candidate(
                    chosen_leg,
                    pseudo_chain,
                    node_pos=node_pos,
                    edge_pull=edge_pull,
                    non_profitable=non_profitable,
                )
                if not chosen_candidate:
                    continue
                chosen_candidate["strategy_pair_signature"] = pair_sig
                chosen_candidate["strategy_phase"] = str(chosen_leg.get("phase", ""))
                if str(chosen_leg.get("phase", "")).startswith("exchange_"):
                    chosen_candidate["chain_pull"] = max(
                        _to_int(chosen_candidate.get("chain_pull", 0), 0),
                        220 if non_profitable else 170,
                    )
                if not self._is_steel_payday_candidate(
                    chosen_candidate,
                    chosen_leg,
                    non_profitable=non_profitable,
                ):
                    continue
                shunt_signature = self._shunt_signature(chosen_candidate)
                shunt_pair_signature = self._shunt_pair_signature(chosen_candidate)
                if shunt_signature in seen_shunt_signatures:
                    continue
                seen_shunt_signatures.add(shunt_signature)

                phase = str(chosen_leg.get("phase", ""))
                reason = (
                    f"Steel payday ({phase}): {chosen_candidate.get('source_name', '?')} -> "
                    f"{chosen_candidate.get('target_name', '?')} "
                    f"({chosen_candidate.get('cargo', '?')}, {chosen_candidate.get('transport_type')}) "
                    f"pair={ore_mill_name}<->{coal_mill_name}"
                )
                action = Action(
                    action="build_shunt",
                    priority=1,
                    reason=reason,
                    payload={
                        "candidate": chosen_candidate,
                        "shunt_signature": shunt_signature,
                        "shunt_pair_signature": shunt_pair_signature,
                        "strategy_tag": "steel_payday",
                        "strategy_phase": phase,
                        "strategy_pair_signature": pair_sig,
                    },
                )
                phase_bonus = {
                    "local_ore": 12.0,
                    "local_coal": 12.0,
                    "exchange_coal": 26.0,
                }.get(phase, 0.0)
                mode = str(chosen_candidate.get("transport_type", "road")).lower()
                mode_bonus = 22.0 if mode == "rail" else 26.0 if mode == "water" else 0.0
                progress_bonus = float(next_idx) * 40.0
                feeder_total = (
                    _to_int(ore_local.get("distance", 0), 0)
                    + _to_int(coal_local.get("distance", 0), 0)
                )
                geometry_bonus = max(0.0, 16.0 - (float(feeder_total) / 300.0))
                score = (
                    float(pair_pull)
                    + phase_bonus
                    + mode_bonus
                    + progress_bonus
                    + geometry_bonus
                )
                ranked_actions.append((pair_distance, score, action))
        if not ranked_actions:
            return []
        min_pair_distance = min(row[0] for row in ranked_actions)
        nearest = [row for row in ranked_actions if row[0] == min_pair_distance]
        nearest.sort(key=lambda row: row[1], reverse=True)
        return [row[2] for row in nearest[: max(1, limit)]]

    def _latest_strategy_pair(self, strategy_tag: str) -> str:
        for rec in reversed(self.memory.get_all()):
            if rec.get("simulated", False):
                continue
            if str(rec.get("strategy_tag", "")) != str(strategy_tag):
                continue
            if not rec.get("success", False):
                continue
            return str(rec.get("strategy_pair_signature", ""))
        return ""

    def _has_successful_strategy_phase(
        self,
        strategy_tag: str,
        strategy_pair_signature: str,
        strategy_phase: str,
        existing_line_ids: Set[str],
    ) -> bool:
        if not strategy_tag or not strategy_pair_signature or not strategy_phase:
            return False
        for rec in reversed(self.memory.get_all()):
            if rec.get("simulated", False):
                continue
            if not rec.get("success", False):
                continue
            if str(rec.get("strategy_tag", "")) != str(strategy_tag):
                continue
            if str(rec.get("strategy_pair_signature", "")) != str(strategy_pair_signature):
                continue
            rec_phase = str(rec.get("strategy_phase", ""))
            if rec_phase != str(strategy_phase):
                # Backward compatibility: older steel selector recorded exchange_ore.
                if not (
                    str(strategy_phase) == "exchange_coal"
                    and rec_phase in {"exchange_ore"}
                ):
                    continue
            rec_lines = [
                str(line_id)
                for line_id in (rec.get("new_line_ids", []) or [])
                if str(line_id)
            ]
            if not rec_lines:
                return True
            if any(line_id in existing_line_ids for line_id in rec_lines):
                return True
        return False

    @staticmethod
    def _is_steel_payday_candidate(
        candidate: Dict[str, Any],
        leg: Dict[str, Any],
        non_profitable: bool = False,
    ) -> bool:
        mode = str(candidate.get("transport_type", "road")).lower()
        distance = _to_int(candidate.get("distance", 0), 0)
        pull = _to_int(candidate.get("chain_pull", 0), 0)
        phase = str(leg.get("phase", ""))
        cargo = str(candidate.get("cargo", "")).upper()
        if cargo not in {"COAL", "IRON_ORE"}:
            return False

        if phase.startswith("local_"):
            if mode != "road":
                return False
            if distance > STEEL_PAYDAY_LOCAL_FEEDER_MAX_DISTANCE_M:
                return False
            return pull >= 60

        if phase.startswith("exchange_"):
            if mode not in {"rail", "water"}:
                return False
            if distance < STEEL_PAYDAY_MIN_PAIR_DISTANCE_M:
                return False
            if distance > RAIL_LONG_FEEDER_MAX_DISTANCE_M:
                return False
            return pull >= (130 if non_profitable else 110)

        return False

    @staticmethod
    def _best_edge(
        incoming: Dict[Tuple[str, str], List[Dict[str, Any]]],
        target_id: str,
        cargo: str,
    ) -> Optional[Dict[str, Any]]:
        edges = incoming.get((str(target_id), str(cargo).upper()), [])
        if not edges:
            return None
        return edges[0]

    @staticmethod
    def _node_distance(
        node_pos: Dict[str, Dict[str, float]],
        source_id: str,
        target_id: str,
    ) -> int:
        source = node_pos.get(str(source_id), {})
        target = node_pos.get(str(target_id), {})
        if not source or not target:
            return 0
        dx = float(source.get("x", 0.0)) - float(target.get("x", 0.0))
        dy = float(source.get("y", 0.0)) - float(target.get("y", 0.0))
        return int(math.sqrt(dx * dx + dy * dy))

    def _candidate_recipe_bridge_actions(
        self,
        survey: Dict[str, Any],
        limit: int = 6,
    ) -> List[Action]:
        dag = survey.get("dag", {}) or {}
        edges = dag.get("edges", []) or []
        if not edges:
            return []

        required_inputs = self._required_and_inputs_by_processor(survey)
        processor_names = self._processor_name_by_id(survey)
        processor_chain_demand = self._processor_chain_demand_by_id(survey)
        node_pos = self._node_position_index(dag)
        node_types = self._node_type_by_id(dag)
        edge_pull = self._edge_chain_pull(dag.get("complete_chains", []))
        non_profitable = self._is_non_profitable(survey)
        road_limit = (
            ROAD_MAX_SHUNT_DISTANCE_RECOVERY_M
            if non_profitable
            else ROAD_MAX_LEG_DISTANCE_NORMAL_M
        )

        ranked: List[Tuple[float, Action]] = []
        seen_signatures: Set[str] = set()
        for edge in edges:
            edge_type = str(edge.get("type", ""))
            if edge_type not in {"raw_to_processor", "processor_to_processor"}:
                continue

            source_id = str(edge.get("source_id", ""))
            target_id = str(edge.get("target_id", ""))
            cargo = str(edge.get("cargo", "")).upper()
            distance = _to_int(edge.get("distance", 0), 0)
            if not source_id or not target_id or not cargo or distance <= 0:
                continue
            if self._is_leg_served(survey, edge):
                continue

            strategy_tag = self._edge_strategy_tag(edge, node_types)
            if not strategy_tag:
                continue

            pull = max(
                _to_int(edge_pull.get((source_id, target_id, cargo), 0), 0),
                _to_int(edge.get("town_demand", 0), 0),
                80,
            )
            if distance >= RAIL_SHORT_FEEDER_MIN_DISTANCE_M and cargo in STRATEGIC_BULK_CARGOS:
                pull = max(pull, 190 if non_profitable else 150)
            pseudo_chain = {
                "town_demand": pull,
                "_effective_score": 40.0 if strategy_tag == "fuel_cycle" else 34.0,
            }
            candidate = self._leg_to_shunt_candidate(
                edge,
                pseudo_chain,
                node_pos=node_pos,
                edge_pull=edge_pull,
                non_profitable=non_profitable,
            )
            if not candidate:
                continue
            if not self._is_strategic_shunt_candidate(
                candidate,
                survey,
                required_inputs,
                processor_names,
                processor_chain_demand,
            ):
                continue

            shunt_signature = self._shunt_signature(candidate)
            if shunt_signature in seen_signatures:
                continue
            seen_signatures.add(shunt_signature)
            if self._has_recent_signature_success(shunt_signature):
                continue
            shunt_pair_signature = self._shunt_pair_signature(candidate)
            # Avoid repeatedly rebuilding the same precursor pair when TF2 uses
            # non-descriptive autogenerated line names.
            if self._has_successful_shunt_pair(shunt_pair_signature):
                continue

            if strategy_tag == "fuel_cycle":
                reason = (
                    f"Fuel cycle precursor: {candidate.get('source_name', '?')} -> "
                    f"{candidate.get('target_name', '?')} ({cargo}, {candidate.get('transport_type')})"
                )
            else:
                reason = (
                    f"Steel payday precursor: {candidate.get('source_name', '?')} -> "
                    f"{candidate.get('target_name', '?')} ({cargo}, {candidate.get('transport_type')})"
                )
            action = Action(
                action="build_shunt",
                priority=2,
                reason=reason,
                payload={
                    "candidate": candidate,
                    "shunt_signature": shunt_signature,
                    "shunt_pair_signature": shunt_pair_signature,
                    "strategy_tag": strategy_tag,
                },
            )
            mode = str(candidate.get("transport_type", "road")).lower()
            score = float(pull)
            score += 28.0 if strategy_tag == "fuel_cycle" else 22.0
            if mode == "water":
                score += 36.0
            elif mode == "rail":
                score += 26.0
            elif distance > road_limit:
                score -= 25.0
            score += min(15.0, float(distance) / 1500.0)
            ranked.append((score, action))

        ranked.sort(key=lambda row: row[0], reverse=True)
        return [row[1] for row in ranked[: max(1, limit)]]

    @staticmethod
    def _chain_signature(chain: Dict[str, Any]) -> str:
        return (
            f"{chain.get('processor_id', '')}:"
            f"{chain.get('town_id', '')}:"
            f"{str(chain.get('final_cargo', '')).upper()}"
        )

    @staticmethod
    def _node_type_by_id(dag: Dict[str, Any]) -> Dict[str, str]:
        out: Dict[str, str] = {}
        for group in ("raw_producers", "processors"):
            for node in dag.get(group, []):
                nid = str(node.get("id", ""))
                if nid:
                    out[nid] = str(node.get("type", "")).lower()
        return out

    @staticmethod
    def _edge_strategy_tag(edge: Dict[str, Any], node_types: Dict[str, str]) -> str:
        target_id = str(edge.get("target_id", ""))
        target_type = node_types.get(target_id, "")
        cargo = str(edge.get("cargo", "")).upper()
        if "steel_mill" in target_type and cargo in {"COAL", "IRON_ORE"}:
            return "steel_payday"
        if "fuel_refinery" in target_type and cargo in {"OIL", "CRUDE", "OIL_SAND", "SAND"}:
            return "fuel_cycle"
        if "oil_refinery" in target_type and cargo in {"CRUDE"}:
            return "fuel_cycle"
        return ""

    @staticmethod
    def _line_matches_connection(
        line: Dict[str, Any],
        source_name: str,
        target_name: str,
        cargo: str,
    ) -> bool:
        if _to_int(line.get("vehicle_count", 0), 0) <= 0:
            return False
        line_name = str(line.get("name", ""))
        line_lc = line_name.lower()
        source_lc = str(source_name).lower()
        target_lc = str(target_name).lower()
        if source_lc and source_lc not in line_lc:
            return False
        if target_lc and target_lc not in line_lc:
            return False
        cargo_uc = str(cargo).upper()
        known = _line_known_cargos(line)
        if cargo_uc in known:
            return True
        return _line_suffix_has_cargo(line_name, cargo_uc)

    def _is_leg_served(self, survey: Dict[str, Any], leg: Dict[str, Any]) -> bool:
        source_name = str(leg.get("source_name", ""))
        target_name = str(leg.get("target_name", ""))
        cargo = str(leg.get("cargo", "")).upper()
        for line in survey.get("lines", []):
            if self._line_matches_connection(line, source_name, target_name, cargo):
                return True
        # TF2 often auto-names lines using only one endpoint (e.g. source + cargo).
        # Allow one-endpoint matching only when this leg is unique for that cargo.
        source_id = str(leg.get("source_id", ""))
        target_id = str(leg.get("target_id", ""))
        if not self._is_unique_cargo_leg(survey, source_id, target_id, cargo):
            return False
        source_lc = source_name.lower()
        target_lc = target_name.lower()
        for line in survey.get("lines", []):
            if _to_int(line.get("vehicle_count", 0), 0) <= 0:
                continue
            line_name = str(line.get("name", ""))
            line_lc = line_name.lower()
            known = _line_known_cargos(line)
            if cargo not in known and not _line_suffix_has_cargo(line_name, cargo):
                continue
            if source_lc and source_lc in line_lc:
                return True
            if target_lc and target_lc in line_lc:
                return True
        return False

    @staticmethod
    def _is_unique_cargo_leg(
        survey: Dict[str, Any],
        source_id: str,
        target_id: str,
        cargo: str,
    ) -> bool:
        source = str(source_id or "")
        target = str(target_id or "")
        cargo_uc = str(cargo or "").upper()
        if not source or not target or not cargo_uc:
            return False

        same_source_targets: Set[str] = set()
        same_target_sources: Set[str] = set()
        for edge in survey.get("dag", {}).get("edges", []):
            edge_cargo = str(edge.get("cargo", "")).upper()
            if edge_cargo != cargo_uc:
                continue
            edge_source = str(edge.get("source_id", ""))
            edge_target = str(edge.get("target_id", ""))
            if not edge_source or not edge_target:
                continue
            if edge_source == source:
                same_source_targets.add(edge_target)
            if edge_target == target:
                same_target_sources.add(edge_source)

        return len(same_source_targets) <= 1 or len(same_target_sources) <= 1

    def _processor_source_ready(
        self,
        survey: Dict[str, Any],
        processor_id: str,
        required_inputs: Dict[str, Set[str]],
        processor_names: Dict[str, str],
    ) -> bool:
        required = set(required_inputs.get(processor_id, set()))
        if not required:
            return True
        pname = processor_names.get(processor_id, "")
        # OR recipes can surface as multiple possibilities, so require any viable input.
        return any(
            self._has_active_processor_input_line(survey, pname, cargo)
            for cargo in required
        )

    def _missing_feeder_legs_for_chain(
        self,
        chain: Dict[str, Any],
        survey: Dict[str, Any],
        required_inputs: Dict[str, Set[str]],
        processor_names: Dict[str, str],
    ) -> List[Dict[str, Any]]:
        seen_keys: Set[Tuple[str, str, str]] = set()
        feeders: List[Dict[str, Any]] = []
        for leg in chain.get("legs", []):
            if str(leg.get("type", "")) == "processor_to_town":
                continue
            key = (
                str(leg.get("source_id", "")),
                str(leg.get("target_id", "")),
                str(leg.get("cargo", "")).upper(),
            )
            if key in seen_keys:
                continue
            seen_keys.add(key)
            feeders.append(leg)

        feeders.sort(
            key=lambda leg: (
                0 if str(leg.get("type", "")) == "raw_to_processor" else 1,
                _to_int(leg.get("distance", 0), 0),
            )
        )

        missing: List[Dict[str, Any]] = []
        for leg in feeders:
            if self._is_leg_served(survey, leg):
                continue
            if str(leg.get("type", "")) == "processor_to_processor":
                source_id = str(leg.get("source_id", ""))
                if not self._processor_source_ready(
                    survey,
                    processor_id=source_id,
                    required_inputs=required_inputs,
                    processor_names=processor_names,
                ):
                    continue
            missing.append(leg)
        return missing

    def _leg_to_shunt_candidate(
        self,
        leg: Dict[str, Any],
        chain: Dict[str, Any],
        node_pos: Dict[str, Dict[str, float]],
        edge_pull: Dict[Tuple[str, str, str], int],
        non_profitable: bool,
    ) -> Optional[Dict[str, Any]]:
        source_id = str(leg.get("source_id", ""))
        target_id = str(leg.get("target_id", ""))
        cargo = str(leg.get("cargo", "")).upper()
        if not source_id or not target_id or not cargo:
            return None
        distance = _to_int(leg.get("distance", 0), 0)
        if distance <= 0:
            return None
        edge_key = (source_id, target_id, cargo)
        chain_pull = max(
            1,
            _to_int(chain.get("town_demand", 0), 1),
            _to_int(edge_pull.get(edge_key, 0), 0),
        )
        preferred_transport = str(leg.get("preferred_transport", "")).lower()
        if preferred_transport in {"road", "rail", "water"}:
            transport_type = preferred_transport
        else:
            transport_type = self._select_shunt_transport(
                source_id,
                target_id,
                distance,
                chain_pull,
                node_pos,
                non_profitable=non_profitable,
            )
        road_limit = (
            ROAD_MAX_SHUNT_DISTANCE_RECOVERY_M
            if non_profitable
            else ROAD_MAX_LEG_DISTANCE_NORMAL_M
        )
        if transport_type == "road" and distance > road_limit:
            return None
        return {
            "source_id": source_id,
            "source_name": str(leg.get("source_name", source_id)),
            "target_id": target_id,
            "target_name": str(leg.get("target_name", target_id)),
            "cargo": cargo,
            "edge_type": str(leg.get("type", "")),
            "distance": distance,
            "transport_type": transport_type,
            "chain_pull": chain_pull,
            "_estimated_cost": _estimate_shunt_cost(distance, transport_type),
            "_effective_score": _to_float(chain.get("_effective_score", chain.get("score", 0.0)), 0.0),
        }

    @staticmethod
    def _chain_profitability_proxy(chain: Dict[str, Any], missing_legs: int) -> float:
        demand = max(1, _to_int(chain.get("town_demand", 0), 1))
        total_distance = max(1, _to_int(chain.get("total_distance", 0), 0))
        if total_distance <= 0:
            total_distance = sum(
                max(0, _to_int(leg.get("distance", 0), 0)) for leg in chain.get("legs", [])
            )
        cargo = str(chain.get("final_cargo", "")).upper()
        cargo_weight = {
            "FOOD": 1.0,
            "CONSTRUCTION_MATERIALS": 1.0,
            "FUEL": 1.1,
            "TOOLS": 1.2,
            "GOODS": 1.4,
            "MACHINES": 1.5,
        }.get(cargo, 1.0)
        distance_factor = max(0.30, 1.0 - (total_distance / 40_000.0))
        readiness_factor = 1.0 / (1.0 + 0.35 * float(max(0, missing_legs)))
        return demand * cargo_weight * distance_factor * readiness_factor

    def _candidate_loop_actions(
        self,
        loop_candidates: List[Dict[str, Any]],
        survey: Dict[str, Any],
        limit: int = 3,
    ) -> List[Action]:
        out: List[Action] = []
        town_ids = set(survey.get("towns", {}).keys())
        for candidate in loop_candidates:
            loop_signature = self._loop_signature(candidate)
            if self._has_recent_signature_success(loop_signature):
                continue
            out.append(
                Action(
                    action="build_multi_stop_loop",
                    priority=2,
                    reason=(
                        "Truck utilization below target; "
                        f"choose multi-stop loop (dist_ratio={candidate.get('loaded_distance_ratio')}, "
                        f"legs={candidate.get('loaded_legs')}/{candidate.get('total_legs')})"
                    ),
                    payload={
                        "candidate": candidate,
                        "town_ids": sorted(town_ids),
                        "loop_signature": loop_signature,
                    },
                )
            )
            if len(out) >= max(1, limit):
                break
        return out

    def _candidate_shunt_actions(
        self,
        shunt_candidates: List[Dict[str, Any]],
        survey: Dict[str, Any],
        limit: int = 6,
    ) -> List[Action]:
        out: List[Action] = []
        required_inputs = self._required_and_inputs_by_processor(survey)
        processor_names = self._processor_name_by_id(survey)
        processor_chain_demand = self._processor_chain_demand_by_id(survey)
        for candidate in shunt_candidates:
            if not self._is_strategic_shunt_candidate(
                candidate,
                survey,
                required_inputs,
                processor_names,
                processor_chain_demand,
            ):
                continue
            shunt_signature = self._shunt_signature(candidate)
            shunt_pair_signature = self._shunt_pair_signature(candidate)
            if self._has_successful_shunt_pair(shunt_pair_signature):
                continue
            if self._has_recent_signature_success(shunt_signature):
                continue
            out.append(
                Action(
                    action="build_shunt",
                    priority=2,
                    reason=(
                        "Early-game/high-throughput shunt opportunity "
                        f"({candidate.get('cargo')} {candidate.get('source_name')} -> "
                        f"{candidate.get('target_name')} via {candidate.get('transport_type')})"
                    ),
                    payload={
                        "candidate": candidate,
                        "shunt_signature": shunt_signature,
                        "shunt_pair_signature": shunt_pair_signature,
                    },
                )
            )
            if len(out) >= max(1, limit):
                break
        return out

    @staticmethod
    def _clamp(value: float, lo: float, hi: float) -> float:
        return min(hi, max(lo, value))

    @staticmethod
    def _median(values: List[float], default: float = 0.0) -> float:
        if not values:
            return default
        ordered = sorted(values)
        mid = len(ordered) // 2
        if len(ordered) % 2:
            return float(ordered[mid])
        return float((ordered[mid - 1] + ordered[mid]) / 2.0)

    @staticmethod
    def _action_identity(action: Action) -> str:
        payload = action.payload if isinstance(action.payload, dict) else {}
        if action.action == "build_shunt":
            pair_sig = str(payload.get("shunt_pair_signature", ""))
            if pair_sig:
                return f"shunt-pair:{pair_sig}"
            shunt_sig = str(payload.get("shunt_signature", ""))
            if shunt_sig:
                return f"shunt:{shunt_sig}"
            cand = payload.get("candidate", {}) if isinstance(payload.get("candidate"), dict) else {}
            return (
                f"shunt:{cand.get('source_id','')}>{cand.get('target_id','')}:"
                f"{str(cand.get('cargo','')).upper()}:{cand.get('transport_type','road')}"
            )
        if action.action == "build_chain":
            chain_id = str(payload.get("target_chain_id", ""))
            if chain_id:
                return f"chain:{chain_id}"
            chain = payload.get("chain", {}) if isinstance(payload.get("chain"), dict) else {}
            return (
                f"chain:{chain.get('processor_id','')}:{chain.get('town_id','')}:"
                f"{str(chain.get('final_cargo','')).upper()}"
            )
        if action.action == "build_multi_stop_loop":
            loop_sig = str(payload.get("loop_signature", ""))
            if loop_sig:
                return loop_sig
        if action.action == "diagnose_line":
            return f"diagnose:{payload.get('line_id','')}"
        return f"{action.action}:{action.reason[:80]}"

    @staticmethod
    def _action_route_label(action: Action) -> str:
        payload = action.payload if isinstance(action.payload, dict) else {}
        if action.action == "build_shunt":
            cand = payload.get("candidate", {}) if isinstance(payload.get("candidate"), dict) else {}
            return (
                f"{cand.get('source_name', '?')} -> {cand.get('target_name', '?')} "
                f"({str(cand.get('cargo', '?')).upper()}, {cand.get('transport_type', 'road')})"
            )
        if action.action == "build_chain":
            chain = payload.get("chain", {}) if isinstance(payload.get("chain"), dict) else {}
            return (
                f"{chain.get('processor', '?')} -> {chain.get('town', '?')} "
                f"({str(chain.get('final_cargo', '?')).upper()})"
            )
        if action.action == "build_multi_stop_loop":
            candidate = payload.get("candidate", {}) if isinstance(payload.get("candidate"), dict) else {}
            stops = candidate.get("stops", []) if isinstance(candidate.get("stops"), list) else []
            if stops:
                return " -> ".join(str(stop.get("name", "?")) for stop in stops)
        return action.reason

    def _select_action_via_rollout(
        self,
        survey: Dict[str, Any],
        candidates: List[Action],
    ) -> Optional[Action]:
        if not candidates:
            return None
        if not MONTE_CARLO_ENABLED:
            return candidates[0]
        if not MONTE_CARLO_LOOKAHEAD_ENABLED or len(candidates) <= 1:
            return self._select_action_via_monte_carlo(survey, candidates)

        current_money = _to_int(survey.get("money", 0), 0)
        if current_money <= 0:
            return self._select_action_via_monte_carlo(survey, candidates)
        focus_cargo = self._focus_cargo_from_unserved(survey)

        base_rows: Dict[str, Tuple[Action, Dict[str, Any], Dict[str, Any]]] = {}
        for action in candidates[:MONTE_CARLO_MAX_CANDIDATES]:
            profile = self._action_monte_carlo_profile(action, survey)
            if not profile:
                continue
            sim = self._simulate_action_monte_carlo(
                profile,
                current_money,
                trials_override=MONTE_CARLO_LOOKAHEAD_TRIALS,
                horizon_override=MONTE_CARLO_LOOKAHEAD_HORIZON_MONTHS,
            )
            action_id = self._action_identity(action)
            prev = base_rows.get(action_id)
            if prev is None or _to_float(sim.get("score", 0.0), 0.0) > _to_float(prev[2].get("score", 0.0), 0.0):
                base_rows[action_id] = (action, profile, sim)

        if not base_rows:
            return self._select_action_via_monte_carlo(survey, candidates)

        ranked_rows = sorted(
            base_rows.values(),
            key=lambda row: (
                _to_float(row[2].get("score", 0.0), 0.0),
                _to_float(row[2].get("monthly_profit_p50", 0.0), 0.0),
            ),
            reverse=True,
        )
        ranked_rows = ranked_rows[: max(6, MONTE_CARLO_LOOKAHEAD_EXPAND_PER_NODE * 2)]

        beam: List[Dict[str, Any]] = [
            {
                "score": 0.0,
                "cash": float(current_money),
                "seq": [],
                "used": set(),
            }
        ]

        for depth in range(max(1, MONTE_CARLO_LOOKAHEAD_HORIZON_STEPS)):
            next_beam: List[Dict[str, Any]] = []
            discount = MONTE_CARLO_LOOKAHEAD_DISCOUNT ** depth
            for node in beam:
                expansions = 0
                for action, profile, _ in ranked_rows:
                    action_id = self._action_identity(action)
                    if action_id in node["used"]:
                        continue
                    sim = self._simulate_action_monte_carlo(
                        profile,
                        int(node["cash"]),
                        trials_override=MONTE_CARLO_LOOKAHEAD_TRIALS,
                        horizon_override=MONTE_CARLO_LOOKAHEAD_HORIZON_MONTHS,
                    )
                    catastrophic = _to_float(sim.get("catastrophic_prob", 1.0), 1.0)
                    if catastrophic > 0.70:
                        continue

                    step_score = _to_float(sim.get("score", 0.0), 0.0)
                    target_chain_cargo = str(action.payload.get("target_chain_cargo", "")).upper()
                    if action.action == "build_chain":
                        step_score += 14.0
                        chain = action.payload.get("chain", {}) if isinstance(action.payload.get("chain"), dict) else {}
                        if str(chain.get("final_cargo", "")).upper() == "MACHINES":
                            step_score += 20.0
                    elif action.action == "build_multi_stop_loop":
                        step_score += 8.0
                    elif action.action == "build_shunt" and str(action.payload.get("target_chain_id", "")):
                        step_score += 6.0
                        if target_chain_cargo == "MACHINES":
                            step_score += 14.0

                    # Focus mode penalty: avoid unrelated shunts while machine
                    # demand remains open.
                    if focus_cargo:
                        if action.action == "build_shunt" and target_chain_cargo and target_chain_cargo != focus_cargo:
                            step_score -= 20.0
                        if action.action == "build_shunt" and not target_chain_cargo:
                            step_score -= 28.0
                        if action.action == "build_chain":
                            chain = action.payload.get("chain", {}) if isinstance(action.payload.get("chain"), dict) else {}
                            if str(chain.get("final_cargo", "")).upper() != focus_cargo:
                                step_score -= 16.0
                        if action.action == "build_multi_stop_loop":
                            step_score -= 14.0

                    cost = _to_float(sim.get("cost", profile.get("cost", 0.0)), 0.0)
                    monthly_profit = _to_float(sim.get("monthly_profit_p50", 0.0), 0.0)
                    next_cash = float(node["cash"]) - cost + (monthly_profit * MONTE_CARLO_LOOKAHEAD_STEP_MONTHS)
                    reserve = max(MONTE_CARLO_MIN_CASH_RESERVE, int(max(0.0, float(node["cash"])) * 0.10))
                    if next_cash < float(reserve):
                        step_score -= 20.0
                    if next_cash < -250_000.0:
                        step_score -= 80.0

                    next_node = {
                        "score": float(node["score"]) + (step_score * discount),
                        "cash": next_cash,
                        "seq": list(node["seq"]) + [(action, sim)],
                        "used": set(node["used"]) | {action_id},
                    }
                    next_beam.append(next_node)
                    expansions += 1
                    if expansions >= max(1, MONTE_CARLO_LOOKAHEAD_EXPAND_PER_NODE):
                        break

            if not next_beam:
                break
            next_beam.sort(key=lambda n: (float(n["score"]), float(n["cash"])), reverse=True)
            beam = next_beam[: max(1, MONTE_CARLO_LOOKAHEAD_BEAM_WIDTH)]

        if not beam or not beam[0].get("seq"):
            return self._select_action_via_monte_carlo(survey, candidates)

        best = max(beam, key=lambda n: (float(n["score"]), float(n["cash"])))
        first_action, first_sim = best["seq"][0]
        plan_labels = [self._action_route_label(item[0]) for item in best["seq"]]

        first_action.payload = dict(first_action.payload)
        first_action.payload["mc"] = first_sim
        first_action.payload["mc_tier"] = "lookahead"
        first_action.payload["mc_sequence"] = plan_labels
        first_action.payload["mc_sequence_score"] = float(best.get("score", 0.0))
        first_action.payload["mc_sequence_horizon"] = len(best["seq"])
        first_action.reason = (
            f"{first_action.reason} "
            f"[MC lookahead steps={len(best['seq'])} plan_score={best.get('score', 0.0):.1f} "
            f"util_p50={first_sim.get('utilization_p50', 0.0):.2f} "
            f"drawdown={first_sim.get('drawdown_prob', 1.0):.2f}]"
        )
        return first_action

    def _action_monte_carlo_profile(
        self,
        action: Action,
        survey: Dict[str, Any],
    ) -> Optional[Dict[str, Any]]:
        action_type = str(action.action)
        if action_type == "build_chain":
            chain = action.payload.get("chain", {})
            planning = action.payload.get("planning", {})
            demand = max(1, _to_int(chain.get("town_demand", 0), 1))
            delivery_distance = max(0, self._delivery_distance(chain))
            input_groups = self._required_input_group_count(chain)
            cargo = str(chain.get("final_cargo", "")).upper()
            cargo_weight = {
                "FOOD": 1.0,
                "CONSTRUCTION_MATERIALS": 1.0,
                "FUEL": 1.1,
                "TOOLS": 1.2,
                "GOODS": 1.4,
                "MACHINES": 1.5,
            }.get(cargo, 1.0)
            cost = max(120_000, _estimate_chain_cost(chain))
            base_util = 0.54 if planning.get("force_road_delivery", False) else 0.62
            if planning.get("allow_rail_feeder_exception", False):
                base_util += 0.05
            if input_groups >= 2:
                base_util += 0.06
            base_util += min(0.16, demand / 700.0)
            base_util -= min(0.22, max(0, delivery_distance - 1800) / 8000.0)
            base_util = self._clamp(base_util, 0.25, 0.92)
            distance_factor = max(0.52, 1.0 - (delivery_distance / 12_000.0))
            monthly_revenue = demand * 1700.0 * cargo_weight * distance_factor
            monthly_maintenance = cost * 0.0042
            monthly_profit = (monthly_revenue * base_util) - monthly_maintenance
            signature = f"chain:{chain.get('processor_id','')}:{chain.get('town_id','')}:{cargo}"
            return {
                "action": action,
                "signature": signature,
                "cost": float(cost),
                "base_utilization": float(base_util),
                "monthly_profit": float(monthly_profit),
                "volatility": 0.28,
            }

        if action_type == "build_shunt":
            candidate = action.payload.get("candidate", {})
            distance = max(0, _to_int(candidate.get("distance", 0), 0))
            pull = max(10, _to_int(candidate.get("chain_pull", 0), 10))
            mode = str(candidate.get("transport_type", "road")).lower()
            cargo = str(candidate.get("cargo", "")).upper()
            strategy_tag = str(action.payload.get("strategy_tag", ""))
            strategy_phase = str(action.payload.get("strategy_phase", ""))
            cost = max(
                100_000,
                _to_int(
                    candidate.get(
                        "_estimated_cost",
                        _estimate_shunt_cost(distance, mode),
                    ),
                    100_000,
                ),
            )
            base_util = 0.80 if distance <= 2500 else 0.72 if distance <= 3500 else 0.60
            if mode == "rail":
                if cargo in STRATEGIC_BULK_CARGOS and pull >= 120:
                    base_util += 0.02
                else:
                    base_util -= 0.05
            elif mode == "water":
                base_util += 0.08
            volatility = 0.35
            if strategy_tag == "steel_payday" and strategy_phase.startswith("exchange_"):
                # Dual-mill exchange legs are explicitly selected for loaded-both-ways behavior.
                base_util = max(base_util, 0.82 if mode == "rail" else 0.85)
                volatility = 0.22
            base_util = self._clamp(base_util, 0.25, 0.90)
            distance_factor = max(0.45, 1.0 - (distance / 11_000.0))
            monthly_revenue = pull * 850.0 * distance_factor
            if strategy_tag == "steel_payday" and strategy_phase.startswith("exchange_"):
                monthly_revenue *= 1.18
            monthly_maintenance = cost * (0.0030 if mode in {"rail", "water"} else 0.0045)
            monthly_profit = (monthly_revenue * base_util) - monthly_maintenance
            signature = (
                f"shunt:{candidate.get('source_id','')}:{candidate.get('target_id','')}:"
                f"{candidate.get('cargo','')}"
            )
            return {
                "action": action,
                "signature": signature,
                "cost": float(cost),
                "base_utilization": float(base_util),
                "monthly_profit": float(monthly_profit),
                "volatility": float(volatility),
            }

        if action_type == "build_multi_stop_loop":
            candidate = action.payload.get("candidate", {})
            cost = max(120_000, _estimate_multi_stop_cost(candidate))
            base_util = self._clamp(
                _to_float(candidate.get("loaded_distance_ratio", 0.0), 0.0),
                0.30,
                0.95,
            )
            loaded_distance = max(1000, _to_int(candidate.get("loaded_distance", 0), 1000))
            monthly_revenue = max(20_000.0, loaded_distance * 14.0) * base_util
            monthly_maintenance = cost * 0.0040
            monthly_profit = monthly_revenue - monthly_maintenance
            signature = str(action.payload.get("loop_signature", "loop"))
            return {
                "action": action,
                "signature": signature,
                "cost": float(cost),
                "base_utilization": float(base_util),
                "monthly_profit": float(monthly_profit),
                "volatility": 0.22,
            }

        return None

    def _simulate_action_monte_carlo(
        self,
        profile: Dict[str, Any],
        current_money: int,
        trials_override: Optional[int] = None,
        horizon_override: Optional[int] = None,
    ) -> Dict[str, Any]:
        cost = float(profile.get("cost", 0.0))
        base_util = float(profile.get("base_utilization", 0.0))
        base_monthly_profit = float(profile.get("monthly_profit", 0.0))
        volatility = float(profile.get("volatility", 0.3))

        trials = max(20, _to_int(trials_override, MONTE_CARLO_TRIALS))
        horizon = max(6, _to_int(horizon_override, MONTE_CARLO_HORIZON_MONTHS))
        reserve = max(MONTE_CARLO_MIN_CASH_RESERVE, int(current_money * 0.12))
        rng = random.Random(f"{profile.get('signature', '')}:{current_money}:{int(cost)}")

        utilization_trials: List[float] = []
        ending_cash: List[float] = []
        min_cash: List[float] = []
        payback_months: List[float] = []
        monthly_profit_samples: List[float] = []

        for _ in range(trials):
            cash = float(current_money) - cost
            min_seen = cash
            util_series: List[float] = []
            recovered_at = float(horizon + 6)

            for month in range(1, horizon + 1):
                ramp = min(1.0, 0.45 + (month / float(horizon)) * 0.75)
                util_noise = rng.gauss(0.0, 0.08 + volatility * 0.06)
                travel_shock = rng.uniform(-0.18, 0.14)
                util = self._clamp(
                    (base_util * ramp) + util_noise + (travel_shock * 0.35),
                    0.10,
                    0.98,
                )
                util_series.append(util)
                profit_noise = rng.gauss(0.0, volatility)
                monthly_profit = base_monthly_profit * (0.8 + 0.4 * util) * (1.0 + profit_noise * 0.35)
                cash += monthly_profit
                min_seen = min(min_seen, cash)
                if recovered_at > horizon and cash >= float(current_money):
                    recovered_at = float(month)

            utilization_trials.append(sum(util_series) / float(len(util_series)))
            ending_cash.append(cash)
            min_cash.append(min_seen)
            payback_months.append(recovered_at)
            monthly_profit_samples.append((cash - (float(current_money) - cost)) / float(horizon))

        util_p50 = self._median(utilization_trials, 0.0)
        drawdown_prob = (
            sum(1 for c in min_cash if c < float(reserve)) / float(trials)
            if trials > 0
            else 1.0
        )
        catastrophic_prob = (
            sum(1 for c in ending_cash if c < 0.0) / float(trials)
            if trials > 0
            else 1.0
        )
        payback_p50 = self._median(payback_months, float(horizon + 6))
        monthly_profit_p50 = self._median(monthly_profit_samples, 0.0)

        score = (
            (monthly_profit_p50 / max(1.0, cost)) * 1200.0
            + util_p50 * 80.0
            - drawdown_prob * 90.0
            - catastrophic_prob * 140.0
            - (payback_p50 / float(horizon)) * 15.0
        )
        accepted = (
            util_p50 >= MONTE_CARLO_MIN_UTILIZATION_P50
            and drawdown_prob <= MONTE_CARLO_MAX_DRAWDOWN_PROB
            and catastrophic_prob <= MONTE_CARLO_MAX_CATASTROPHIC_PROB
        )

        return {
            "score": float(score),
            "accepted": bool(accepted),
            "utilization_p50": float(util_p50),
            "drawdown_prob": float(drawdown_prob),
            "catastrophic_prob": float(catastrophic_prob),
            "payback_p50_months": float(payback_p50),
            "monthly_profit_p50": float(monthly_profit_p50),
            "cost": float(cost),
            "reserve": int(reserve),
            "trials": int(trials),
            "horizon_months": int(horizon),
        }

    def _select_action_via_monte_carlo(
        self,
        survey: Dict[str, Any],
        candidates: List[Action],
    ) -> Optional[Action]:
        if not candidates:
            return None
        if not MONTE_CARLO_ENABLED:
            return candidates[0]

        current_money = _to_int(survey.get("money", 0), 0)
        if current_money <= 0:
            return None
        non_profitable = self._is_non_profitable(survey)

        evaluations: List[Tuple[Action, Dict[str, Any]]] = []
        for action in candidates[:MONTE_CARLO_MAX_CANDIDATES]:
            profile = self._action_monte_carlo_profile(action, survey)
            if not profile:
                continue
            sim = self._simulate_action_monte_carlo(profile, current_money)
            evaluations.append((action, sim))

        if not evaluations:
            return None

        tiers = [
            {
                "name": "strict",
                "util": MONTE_CARLO_MIN_UTILIZATION_P50,
                "drawdown": MONTE_CARLO_MAX_DRAWDOWN_PROB,
                "cat": MONTE_CARLO_MAX_CATASTROPHIC_PROB,
                "profit": 0.0,
            },
            {
                "name": "relaxed",
                "util": MONTE_CARLO_RELAXED_UTILIZATION_P50 if non_profitable else 0.64,
                "drawdown": MONTE_CARLO_RELAXED_DRAWDOWN_PROB if non_profitable else 0.55,
                "cat": MONTE_CARLO_RELAXED_CATASTROPHIC_PROB if non_profitable else 0.27,
                "profit": -1500.0 if non_profitable else 0.0,
            },
            {
                "name": "salvage",
                "util": MONTE_CARLO_SALVAGE_UTILIZATION_P50,
                "drawdown": MONTE_CARLO_SALVAGE_DRAWDOWN_PROB,
                "cat": MONTE_CARLO_SALVAGE_CATASTROPHIC_PROB,
                "profit": -2500.0 if non_profitable else -500.0,
            },
        ]

        chosen_tier = ""
        shortlist: List[Tuple[Action, Dict[str, Any]]] = []
        for tier in tiers:
            shortlist = [
                (act, sim)
                for act, sim in evaluations
                if _to_float(sim.get("utilization_p50", 0.0), 0.0) >= float(tier["util"])
                and _to_float(sim.get("drawdown_prob", 1.0), 1.0) <= float(tier["drawdown"])
                and _to_float(sim.get("catastrophic_prob", 1.0), 1.0) <= float(tier["cat"])
                and _to_float(sim.get("monthly_profit_p50", -999999.0), -999999.0) >= float(tier["profit"])
            ]
            if shortlist:
                chosen_tier = str(tier["name"])
                break

        if not shortlist:
            # Last resort: still pick the safest simulated candidate so we do not
            # stall indefinitely when all options narrowly miss tier thresholds.
            fallback = [
                row for row in evaluations
                if _to_float(row[1].get("drawdown_prob", 1.0), 1.0) <= 0.90
                and _to_float(row[1].get("catastrophic_prob", 1.0), 1.0) <= 0.45
            ]
            if not fallback:
                return None
            chosen_tier = "forced"
            shortlist = fallback

        best_action, best_sim = max(
            shortlist,
            key=lambda row: (
                _to_float(row[1].get("score", 0.0), 0.0),
                _to_float(row[1].get("monthly_profit_p50", 0.0), 0.0),
            ),
        )
        best_action.payload = dict(best_action.payload)
        best_action.payload["mc"] = best_sim
        best_action.payload["mc_tier"] = chosen_tier or "strict"
        best_action.reason = (
            f"{best_action.reason} "
            f"[MC tier={chosen_tier or 'strict'} score={best_sim.get('score', 0.0):.1f} "
            f"util_p50={best_sim.get('utilization_p50', 0.0):.2f} "
            f"drawdown={best_sim.get('drawdown_prob', 1.0):.2f}]"
        )
        return best_action

    @staticmethod
    def _is_non_profitable(survey: Dict[str, Any]) -> bool:
        dashboard = survey.get("dashboard", {}) or {}
        money_rate = _to_float(dashboard.get("money_rate", 0.0), 0.0)
        trend = str(dashboard.get("money_trend", "")).lower()
        if trend == "declining":
            return True
        return money_rate < 0.0

    @staticmethod
    def _delivery_distance(chain: Dict[str, Any]) -> int:
        for leg in chain.get("legs", []):
            if str(leg.get("type", "")) == "processor_to_town":
                return _to_int(leg.get("distance", 0), 0)
        return 0

    @staticmethod
    def _required_input_group_count(chain: Dict[str, Any]) -> int:
        count = 0
        for group in chain.get("input_groups", []):
            gtype = str(group.get("type", "")).lower()
            if gtype == "and" and str(group.get("cargo", "")):
                count += 1
            elif gtype == "or" and group.get("alternatives", []):
                # OR alternatives still represent a required input group.
                count += 1
        return count

    def _chain_planning_directives(self, chain: Dict[str, Any], survey: Dict[str, Any]) -> Dict[str, Any]:
        non_profitable = self._is_non_profitable(survey)
        demand = _to_int(chain.get("town_demand", 0), 0)
        delivery_distance = self._delivery_distance(chain)
        input_group_count = self._required_input_group_count(chain)
        allow_rail_feeder_exception = (
            (not non_profitable)
            and input_group_count >= 2
            and demand >= RAIL_SHORT_FEEDER_MIN_CHAIN_DEMAND
            and delivery_distance <= ROAD_MAX_LEG_DISTANCE_NORMAL_M
        )
        return {
            "non_profitable": non_profitable,
            # P2P rail delivery is currently modeled as 50% loaded/deadhead.
            "force_road_delivery": (
                RAIL_P2P_PROJECTED_LOADED_UTILIZATION < RAIL_MIN_LOADED_UTILIZATION
            ),
            "allow_rail_feeder_exception": allow_rail_feeder_exception,
        }

    def _rank_candidate_chains(self, survey: Dict[str, Any]) -> List[Dict[str, Any]]:
        money = survey.get("money", 0)
        served_pairs = survey.get("served_pairs", set())
        all_chains = survey.get("dag", {}).get("complete_chains", [])
        town_map = survey.get("towns", {}) or {}
        non_profitable = self._is_non_profitable(survey)

        candidates = []
        for chain in all_chains:
            if not chain.get("feasible", False):
                continue
            town_id = str(chain.get("town_id", ""))
            cargo = str(chain.get("final_cargo", "")).upper()
            demand = _to_int(chain.get("town_demand", 0))
            if demand <= 0:
                continue
            # Safety guard: only build final delivery if the live town-demand
            # snapshot confirms this exact cargo is demanded by the target town.
            live_town = town_map.get(town_id, {})
            live_demands = live_town.get("demands", {}) if isinstance(live_town, dict) else {}
            if _to_int((live_demands or {}).get(cargo, 0), 0) <= 0:
                continue
            if (town_id, cargo) in served_pairs:
                continue

            legs = chain.get("legs", [])
            if not isinstance(legs, list):
                continue
            road_leg_limit = (
                ROAD_MAX_LEG_DISTANCE_RECOVERY_M if non_profitable else ROAD_MAX_LEG_DISTANCE_NORMAL_M
            )
            delivery_distance = self._delivery_distance(chain)
            delivery_limit = road_leg_limit + (1200 if non_profitable else 2200)
            if delivery_distance > delivery_limit:
                continue
            feeder_too_long = any(
                _to_int(leg.get("distance", 0)) > RAIL_LONG_FEEDER_MAX_DISTANCE_M
                for leg in legs
                if str(leg.get("type", "")) != "processor_to_town"
            )
            if feeder_too_long:
                continue

            estimated_cost = _estimate_chain_cost(chain)
            max_budget_fraction = NON_PROFITABLE_CHAIN_BUDGET_FRACTION if non_profitable else 0.4
            if money > 0 and estimated_cost > int(money * max_budget_fraction):
                continue

            feeder_count = sum(
                1 for leg in legs if leg.get("type") != "processor_to_town"
            )
            score = _to_float(chain.get("score", 0.0))
            if feeder_count <= 1:
                score += 20
            elif feeder_count >= 3:
                score -= 15
            if cargo in {"FOOD", "CONSTRUCTION_MATERIALS", "FUEL", "TOOLS"}:
                score += 8
            leg_cargos = {str(leg.get("cargo", "")).upper() for leg in legs}
            required_inputs = {
                str(group.get("cargo", "")).upper()
                for group in chain.get("input_groups", [])
                if str(group.get("type", "")).lower() == "and"
            }
            # Prioritize proven profitable strategic templates.
            if cargo == "FUEL" and {"CRUDE", "OIL"} <= leg_cargos:
                score += 24
            if "STEEL" in required_inputs or {"COAL", "IRON_ORE"} <= leg_cargos:
                score += 14
            if non_profitable:
                if feeder_count <= 2:
                    score += 10
                if delivery_distance > ROAD_MAX_LEG_DISTANCE_RECOVERY_M:
                    score -= 18
                # Prefer routes that can stay road-profitable while recovering.
                score -= max(0, delivery_distance - 3000) / 600.0

            candidate = dict(chain)
            candidate["_effective_score"] = score
            candidate["_estimated_cost"] = estimated_cost
            candidates.append(candidate)

        candidates.sort(
            key=lambda c: (
                _to_float(c.get("_effective_score", 0.0)),
                _to_int(c.get("town_demand", 0)),
            ),
            reverse=True,
        )
        return candidates

    def _should_prioritize_multi_stop(self, survey: Dict[str, Any]) -> bool:
        if not ENABLE_PSEUDO_MULTI_STOP_EXECUTION:
            return False
        utilization = _to_float(survey.get("truck_utilization", 0.0), 0.0)
        if utilization >= TRUCK_UTILIZATION_TARGET_MIN:
            return False
        return bool(survey.get("dag", {}).get("multi_stop_candidates", []))

    def _should_prioritize_shunt(self, survey: Dict[str, Any]) -> bool:
        year = _to_int(survey.get("year", 0), 0)
        utilization = _to_float(survey.get("truck_utilization", 0.0), 0.0)
        has_candidates = bool(survey.get("dag", {}).get("edges", []))
        if not has_candidates:
            return False
        if year <= SHUNT_EARLY_YEAR_MAX:
            return True
        return utilization < TRUCK_UTILIZATION_TARGET_MIN

    def _rank_multi_stop_candidates(self, survey: Dict[str, Any]) -> List[Dict[str, Any]]:
        money = _to_int(survey.get("money", 0), 0)
        town_ids = set(survey.get("towns", {}).keys())
        candidates = []
        for cand in survey.get("dag", {}).get("multi_stop_candidates", []):
            dist_ratio = _to_float(cand.get("loaded_distance_ratio", 0.0), 0.0)
            leg_ratio = _to_float(cand.get("loaded_leg_ratio", 0.0), 0.0)
            if dist_ratio < TRUCK_UTILIZATION_TARGET_MIN:
                continue
            if leg_ratio < (2.0 / 3.0):
                continue
            buildable_loaded_legs = 0
            for leg in cand.get("legs", []):
                if not leg.get("loaded", False):
                    continue
                source_id = str(leg.get("source_id", ""))
                target_id = str(leg.get("target_id", ""))
                # Buildable currently means industry->industry or industry->town.
                if source_id in town_ids:
                    continue
                buildable_loaded_legs += 1
            if buildable_loaded_legs < 2:
                continue
            estimated_cost = _estimate_multi_stop_cost(cand)
            if money > 0 and estimated_cost > int(money * 0.5):
                continue

            score = _to_float(cand.get("score", 0.0), 0.0)
            # Prefer loops closer to 80%+ loaded distance.
            score += max(0.0, dist_ratio - TRUCK_UTILIZATION_TARGET_HIGH) * 50.0
            score += leg_ratio * 10.0

            candidate = dict(cand)
            candidate["_effective_score"] = score
            candidate["_estimated_cost"] = estimated_cost
            candidates.append(candidate)

        candidates.sort(
            key=lambda c: (
                _to_float(c.get("_effective_score", 0.0), 0.0),
                _to_float(c.get("loaded_distance_ratio", 0.0), 0.0),
                _to_float(c.get("loaded_leg_ratio", 0.0), 0.0),
            ),
            reverse=True,
        )
        return candidates

    def _build_loop_action(self, loop_candidates: List[Dict[str, Any]], survey: Dict[str, Any]) -> Optional[Action]:
        town_ids = set(survey.get("towns", {}).keys())
        for candidate in loop_candidates:
            loop_signature = self._loop_signature(candidate)
            if self._has_recent_signature_success(loop_signature):
                continue
            return Action(
                action="build_multi_stop_loop",
                priority=2,
                reason=(
                    "Truck utilization below target; "
                    f"choose multi-stop loop (dist_ratio={candidate.get('loaded_distance_ratio')}, "
                    f"legs={candidate.get('loaded_legs')}/{candidate.get('total_legs')})"
                ),
                payload={
                    "candidate": candidate,
                    "town_ids": sorted(town_ids),
                    "loop_signature": loop_signature,
                },
            )
        return None

    def _build_shunt_action(
        self,
        shunt_candidates: List[Dict[str, Any]],
        survey: Dict[str, Any],
    ) -> Optional[Action]:
        required_inputs = self._required_and_inputs_by_processor(survey)
        processor_names = self._processor_name_by_id(survey)
        processor_chain_demand = self._processor_chain_demand_by_id(survey)
        for candidate in shunt_candidates:
            if not self._is_strategic_shunt_candidate(
                candidate,
                survey,
                required_inputs,
                processor_names,
                processor_chain_demand,
            ):
                continue
            shunt_signature = self._shunt_signature(candidate)
            shunt_pair_signature = self._shunt_pair_signature(candidate)
            if self._has_successful_shunt_pair(shunt_pair_signature):
                continue
            if self._has_recent_signature_success(shunt_signature):
                continue
            return Action(
                action="build_shunt",
                priority=2,
                reason=(
                    "Early-game/high-throughput shunt opportunity "
                    f"({candidate.get('cargo')} {candidate.get('source_name')} -> "
                    f"{candidate.get('target_name')} via {candidate.get('transport_type')})"
                ),
                payload={
                    "candidate": candidate,
                    "shunt_signature": shunt_signature,
                    "shunt_pair_signature": shunt_pair_signature,
                },
            )
        return None

    def _has_recent_signature_success(self, signature: str, window_seconds: int = 1800) -> bool:
        if not signature:
            return False
        now = time.time()
        for rec in reversed(self.memory.get_all()):
            if not rec.get("success", False):
                continue
            age = now - float(rec.get("timestamp", 0))
            if age > window_seconds:
                return False
            if str(rec.get("loop_signature", "")) == signature:
                return True
            if str(rec.get("shunt_signature", "")) == signature:
                return True
        return False

    @staticmethod
    def _loop_signature(candidate: Dict[str, Any]) -> str:
        stop_ids = [str(s.get("id", "")) for s in candidate.get("stops", []) if s.get("id") is not None]
        return "loop:" + ">".join(stop_ids)

    @staticmethod
    def _shunt_signature(candidate: Dict[str, Any]) -> str:
        return (
            "shunt:"
            f"{candidate.get('source_id', '')}>"
            f"{candidate.get('target_id', '')}:"
            f"{str(candidate.get('cargo', '')).upper()}:"
            f"{candidate.get('transport_type', 'road')}"
        )

    @staticmethod
    def _shunt_pair_signature(candidate: Dict[str, Any]) -> str:
        return (
            "shunt-pair:"
            f"{candidate.get('source_id', '')}>"
            f"{candidate.get('target_id', '')}"
        )

    def _has_successful_shunt_pair(self, pair_signature: str) -> bool:
        if not pair_signature:
            return False
        for rec in reversed(self.memory.get_all()):
            if rec.get("simulated", False):
                continue
            rec_pair = str(rec.get("shunt_pair_signature", ""))
            if not rec_pair:
                legacy = str(rec.get("shunt_signature", ""))
                if legacy.startswith("shunt:") and ":" in legacy:
                    rec_pair = "shunt-pair:" + legacy[len("shunt:"):].split(":", 1)[0]
            if rec_pair != pair_signature:
                continue
            if rec.get("success", False):
                return True
        return False

    def _allow_shunts_now(self) -> bool:
        """Avoid back-to-back successful shunt cycles."""
        for rec in reversed(self.memory.get_all()):
            if rec.get("simulated", False):
                continue
            if not rec.get("success", False):
                continue
            return str(rec.get("action", rec.get("action_type", ""))) != "build_shunt"
        return True

    @staticmethod
    def _required_and_inputs_by_processor(survey: Dict[str, Any]) -> Dict[str, Set[str]]:
        required: Dict[str, Set[str]] = {}
        for node in survey.get("dag", {}).get("processors", []):
            pid = str(node.get("id", ""))
            if not pid:
                continue
            for cargo in node.get("inputs", []):
                cargo_uc = str(cargo).upper().strip()
                if cargo_uc:
                    required.setdefault(pid, set()).add(cargo_uc)

        # Also incorporate explicit chain input groups where present.
        for chain in survey.get("dag", {}).get("complete_chains", []):
            pid = str(chain.get("processor_id", ""))
            if not pid:
                continue
            for group in chain.get("input_groups", []):
                if str(group.get("type", "")) != "and":
                    continue
                cargo = str(group.get("cargo", "")).upper()
                if cargo:
                    required.setdefault(pid, set()).add(cargo)
        return required

    @staticmethod
    def _processor_chain_demand_by_id(survey: Dict[str, Any]) -> Dict[str, int]:
        demand: Dict[str, int] = {}
        for chain in survey.get("dag", {}).get("complete_chains", []):
            pid = str(chain.get("processor_id", ""))
            if not pid:
                continue
            demand[pid] = demand.get(pid, 0) + max(0, _to_int(chain.get("town_demand", 0), 0))
        return demand

    @staticmethod
    def _processor_name_by_id(survey: Dict[str, Any]) -> Dict[str, str]:
        names: Dict[str, str] = {}
        for node in survey.get("dag", {}).get("processors", []):
            pid = str(node.get("id", ""))
            if pid:
                names[pid] = str(node.get("name", ""))
        return names

    @staticmethod
    def _has_active_processor_input_line(
        survey: Dict[str, Any],
        processor_name: str,
        cargo: str,
    ) -> bool:
        target_lc = str(processor_name).lower()
        cargo_uc = str(cargo).upper()
        for line in survey.get("lines", []):
            if _to_int(line.get("vehicle_count", 0), 0) <= 0:
                continue
            line_name = str(line.get("name", ""))
            if target_lc and target_lc not in line_name.lower():
                continue
            known = _line_known_cargos(line)
            if cargo_uc in known or _line_suffix_has_cargo(line_name, cargo_uc):
                return True
        return False

    def _is_strategic_shunt_candidate(
        self,
        candidate: Dict[str, Any],
        survey: Dict[str, Any],
        required_inputs: Dict[str, Set[str]],
        processor_names: Dict[str, str],
        processor_chain_demand: Dict[str, int],
    ) -> bool:
        transport_type = str(candidate.get("transport_type", "road")).lower()
        pull = _to_int(candidate.get("chain_pull", 0), 0)
        distance = _to_int(candidate.get("distance", 0), 0)
        target_id = str(candidate.get("target_id", ""))
        source_id = str(candidate.get("source_id", ""))
        source_name = str(candidate.get("source_name", ""))
        edge_type = str(candidate.get("edge_type", ""))
        cargo = str(candidate.get("cargo", "")).upper()
        non_profitable = self._is_non_profitable(survey)
        road_limit = (
            ROAD_MAX_SHUNT_DISTANCE_RECOVERY_M
            if non_profitable
            else ROAD_MAX_LEG_DISTANCE_NORMAL_M
        )
        if transport_type == "water":
            if distance < WATER_MIN_DISTANCE_M:
                return False
            return pull >= (60 if edge_type == "raw_to_processor" else 80)
        if transport_type == "rail":
            if distance > RAIL_LONG_FEEDER_MAX_DISTANCE_M:
                return False
            rail_pull_min = RAIL_SHORT_FEEDER_MIN_CHAIN_DEMAND
            if non_profitable:
                rail_pull_min = 90
            if cargo in STRATEGIC_BULK_CARGOS:
                rail_pull_min = min(rail_pull_min, 80 if non_profitable else 70)
            if pull < rail_pull_min:
                return False
        if transport_type not in {"road", "rail", "water"}:
            return False

        target_chain_demand = max(0, _to_int(processor_chain_demand.get(target_id, 0), 0))
        if transport_type == "road" and distance > road_limit:
            return False

        # Block processor->processor links until the source processor is fed.
        source_required = set(required_inputs.get(source_id, set()))
        source_ready = True
        if source_required:
            canonical_source_name = processor_names.get(source_id, source_name)
            # Use ANY-input readiness so OR recipes are not over-constrained.
            source_ready = any(
                self._has_active_processor_input_line(survey, canonical_source_name, need)
                for need in source_required
            )
        if edge_type == "processor_to_processor" and not source_ready:
            return False

        # Primary: complete a multi-input target processor.
        required = set(required_inputs.get(target_id, set()))
        if len(required) >= 2:
            other_required = [c for c in required if c != cargo]
            if other_required:
                processor_name = processor_names.get(target_id, str(candidate.get("target_name", "")))
                if any(
                    self._has_active_processor_input_line(survey, processor_name, other)
                    for other in other_required
                ):
                    return True

        # Raw-first bridge: always allow short, high-pull raw feeders.
        if transport_type == "road":
            if (
                edge_type == "raw_to_processor"
                and distance <= road_limit
                and pull >= 20
            ):
                return True

        # Single-input priming: explicitly permit seeding a processor's sole input
        # when this unlocks a downstream chain.
        if edge_type == "raw_to_processor" and len(required) == 1 and cargo in required:
            if pull >= 80 and target_chain_demand >= 60:
                return True

        # Strategic rail feeders for high-volume steel/fuel chains.
        if (
            transport_type == "rail"
            and edge_type == "raw_to_processor"
            and cargo in STRATEGIC_BULK_CARGOS
            and pull >= 70
        ):
            return True

        # Allow short processor-to-processor feeders only when source is proven ready.
        if edge_type == "processor_to_processor" and source_ready:
            if pull >= 70 and target_chain_demand >= 40:
                return True

        return False

    def _loop_has_input_coverage(self, candidate: Dict[str, Any], survey: Dict[str, Any]) -> bool:
        """Require multi-stop candidates to satisfy processor input groups in-loop.

        Prevents choosing loops that only feed one input into multi-input processors.
        """
        processor_groups: Dict[str, List[Dict[str, Any]]] = {}
        for chain in survey.get("dag", {}).get("complete_chains", []):
            pid = str(chain.get("processor_id", ""))
            if not pid:
                continue
            groups = chain.get("input_groups", [])
            if groups and pid not in processor_groups:
                processor_groups[pid] = groups

        provided: Dict[str, Set[str]] = {}
        for leg in candidate.get("legs", []):
            if not leg.get("loaded", False):
                continue
            target_id = str(leg.get("target_id", ""))
            for cargo in leg.get("cargos", []):
                provided.setdefault(target_id, set()).add(str(cargo).upper())

        for stop in candidate.get("stops", []):
            sid = str(stop.get("id", ""))
            groups = processor_groups.get(sid)
            if not groups:
                continue
            supplied = provided.get(sid, set())
            for group in groups:
                gtype = str(group.get("type", ""))
                if gtype == "and":
                    cargo = str(group.get("cargo", "")).upper()
                    if cargo and cargo not in supplied:
                        return False
                elif gtype == "or":
                    alts = [str(a).upper() for a in group.get("alternatives", [])]
                    if alts and not any(a in supplied for a in alts):
                        return False
        return True

    def _rank_shunt_candidates(self, survey: Dict[str, Any]) -> List[Dict[str, Any]]:
        dag = survey.get("dag", {})
        money = _to_int(survey.get("money", 0), 0)
        non_profitable = self._is_non_profitable(survey)
        chain_pull = self._edge_chain_pull(dag.get("complete_chains", []))
        node_pos = self._node_position_index(dag)

        candidates: List[Dict[str, Any]] = []
        for edge in dag.get("edges", []):
            etype = str(edge.get("type", ""))
            if etype not in {"raw_to_processor", "processor_to_processor"}:
                continue
            cargo = str(edge.get("cargo", "")).upper()
            if not cargo or cargo in FINAL_GOODS:
                continue

            source_id = str(edge.get("source_id", ""))
            target_id = str(edge.get("target_id", ""))
            if not source_id or not target_id or source_id == target_id:
                continue

            distance = _to_int(edge.get("distance", 0), 0)
            if distance <= 0 or distance > 25000:
                continue

            pull = _to_int(chain_pull.get((source_id, target_id, cargo), 0), 0)
            if pull <= 0 and etype != "raw_to_processor":
                continue

            transport_type = self._select_shunt_transport(
                source_id, target_id, distance, pull, node_pos, non_profitable=non_profitable
            )
            if transport_type == "road":
                road_shunt_limit = (
                    ROAD_MAX_SHUNT_DISTANCE_RECOVERY_M
                    if non_profitable
                    else ROAD_MAX_LEG_DISTANCE_NORMAL_M
                )
                if distance > road_shunt_limit:
                    continue
            if transport_type == "water":
                mode_bonus = 10.0
            elif transport_type == "rail":
                mode_bonus = 6.0
            else:
                mode_bonus = 0.0

            score = (
                pull * 2.0
                + (distance / 1000.0)
                + (8.0 if etype == "raw_to_processor" else 4.0)
                + mode_bonus
            )
            if non_profitable and transport_type == "rail":
                score -= 50.0
            estimated_cost = _estimate_shunt_cost(distance, transport_type)
            if money > 0 and estimated_cost > int(money * (0.35 if non_profitable else 0.5)):
                continue

            candidates.append(
                {
                    "source_id": source_id,
                    "source_name": str(edge.get("source_name", source_id)),
                    "target_id": target_id,
                    "target_name": str(edge.get("target_name", target_id)),
                    "cargo": cargo,
                    "edge_type": etype,
                    "distance": distance,
                    "transport_type": transport_type,
                    "chain_pull": pull,
                    "_estimated_cost": estimated_cost,
                    "_effective_score": score,
                }
            )

        candidates.sort(
            key=lambda c: (
                _to_float(c.get("_effective_score", 0.0), 0.0),
                _to_int(c.get("chain_pull", 0), 0),
                _to_int(c.get("distance", 0), 0),
            ),
            reverse=True,
        )
        return candidates

    @staticmethod
    def _edge_chain_pull(chains: List[Dict[str, Any]]) -> Dict[Tuple[str, str, str], int]:
        pull: Dict[Tuple[str, str, str], int] = {}
        for chain in chains:
            demand = _to_int(chain.get("town_demand", 0), 0)
            for leg in chain.get("legs", []):
                sid = str(leg.get("source_id", ""))
                tid = str(leg.get("target_id", ""))
                cargo = str(leg.get("cargo", "")).upper()
                if not sid or not tid or not cargo:
                    continue
                key = (sid, tid, cargo)
                pull[key] = pull.get(key, 0) + max(1, demand)
        return pull

    @staticmethod
    def _node_position_index(dag: Dict[str, Any]) -> Dict[str, Dict[str, float]]:
        idx: Dict[str, Dict[str, float]] = {}
        for group in ("raw_producers", "processors"):
            for node in dag.get(group, []):
                nid = str(node.get("id", ""))
                if not nid:
                    continue
                idx[nid] = {
                    "x": _to_float(node.get("x", 0), 0.0),
                    "y": _to_float(node.get("y", 0), 0.0),
                }
        return idx

    def _select_shunt_transport(
        self,
        source_id: str,
        target_id: str,
        distance: int,
        chain_pull: int,
        node_pos: Dict[str, Dict[str, float]],
        non_profitable: bool = False,
    ) -> str:
        if distance >= WATER_MIN_DISTANCE_M:
            source = node_pos.get(source_id, {})
            target = node_pos.get(target_id, {})
            if source and target:
                water = self.ipc.send(
                    "check_water_path",
                    {
                        "x1": str(source.get("x", 0.0)),
                        "y1": str(source.get("y", 0.0)),
                        "x2": str(target.get("x", 0.0)),
                        "y2": str(target.get("y", 0.0)),
                        "samples": "24",
                    },
                    timeout=8.0,
                )
                if water and water.get("status") == "ok":
                    if str(water.get("data", {}).get("ship_viable", "false")).lower() == "true":
                        if chain_pull >= 60:
                            return "water"
        rail_pull_threshold = RAIL_BASE_PULL_THRESHOLD
        if non_profitable:
            rail_pull_threshold += 40
        if (
            chain_pull >= rail_pull_threshold
            and distance >= RAIL_SHORT_FEEDER_MIN_DISTANCE_M
            and distance <= RAIL_LONG_FEEDER_MAX_DISTANCE_M
        ):
            return "rail"
        if distance >= 9000 and (not non_profitable) and chain_pull >= 100:
            return "rail"
        return "road"


class Planner:
    @staticmethod
    def _delivery_transport_for_chain(
        chain: Dict[str, Any],
        planning: Optional[Dict[str, Any]] = None,
    ) -> str:
        planning = planning or {}
        if planning.get("force_road_delivery", False):
            return "road"
        final_cargo = str(chain.get("final_cargo", "")).upper()
        for leg in chain.get("legs", []):
            if str(leg.get("type", "")) != "processor_to_town":
                continue
            if final_cargo and (
                RAIL_P2P_PROJECTED_LOADED_UTILIZATION < RAIL_MIN_LOADED_UTILIZATION
            ):
                return "road"
            distance = _to_int(leg.get("distance", 0), 0)
            if distance >= (RAIL_SHORT_FEEDER_MAX_DISTANCE_M + 2500):
                return "rail"
            return "road"
        return "road"

    @staticmethod
    def _required_input_group_count(chain: Dict[str, Any]) -> int:
        count = 0
        for group in chain.get("input_groups", []):
            gtype = str(group.get("type", "")).lower()
            if gtype == "and" and str(group.get("cargo", "")):
                count += 1
            elif gtype == "or" and group.get("alternatives", []):
                count += 1
        return count

    @staticmethod
    def _is_feeder_rail_candidate(
        chain: Dict[str, Any],
        leg: Dict[str, Any],
        planning: Optional[Dict[str, Any]] = None,
    ) -> bool:
        planning = planning or {}
        if not planning.get("allow_rail_feeder_exception", False):
            return False
        leg_type = str(leg.get("type", ""))
        if leg_type not in {"raw_to_processor", "processor_to_processor"}:
            return False
        cargo = str(leg.get("cargo", "")).upper()
        if cargo not in RAIL_FEEDER_ELIGIBLE_CARGOS:
            return False
        distance = _to_int(leg.get("distance", 0), 0)
        if distance < RAIL_SHORT_FEEDER_MIN_DISTANCE_M:
            return False
        if distance > RAIL_SHORT_FEEDER_MAX_DISTANCE_M:
            return False
        chain_demand = _to_int(chain.get("town_demand", 0), 0)
        if chain_demand < RAIL_SHORT_FEEDER_MIN_CHAIN_DEMAND:
            return False
        if Planner._required_input_group_count(chain) < 2:
            return False
        return True

    def _select_rail_feeder_key(
        self,
        chain: Dict[str, Any],
        feeder_legs: List[Dict[str, Any]],
        planning: Optional[Dict[str, Any]] = None,
    ) -> Optional[Tuple[str, str, str]]:
        """At most one feeder leg becomes rail to contain early capital usage."""
        best_key: Optional[Tuple[str, str, str]] = None
        best_score = -1
        planning = planning or {}
        for leg in feeder_legs:
            if not self._is_feeder_rail_candidate(chain, leg, planning=planning):
                continue
            key = (
                str(leg.get("source_id", "")),
                str(leg.get("target_id", "")),
                str(leg.get("cargo", "")),
            )
            distance = _to_int(leg.get("distance", 0), 0)
            # Within the short-feeder window, prefer the longest leg first.
            if distance > best_score:
                best_score = distance
                best_key = key
        return best_key

    def create_plan(self, action: Action) -> Dict[str, Any]:
        if action.action == "diagnose_line":
            issue = action.payload
            return {
                "name": f"Diagnose line {issue.get('line_id', '?')}",
                "action": "diagnose_line",
                "steps": [],
                "metadata": issue,
            }

        if action.action == "build_multi_stop_loop":
            candidate = action.payload.get("candidate", {})
            town_ids = set(action.payload.get("town_ids", []))
            loop_signature = str(action.payload.get("loop_signature", ""))
            return self._plan_multi_stop_loop(candidate, town_ids, loop_signature)

        if action.action == "build_shunt":
            candidate = action.payload.get("candidate", {})
            shunt_signature = str(action.payload.get("shunt_signature", ""))
            shunt_pair_signature = str(action.payload.get("shunt_pair_signature", ""))
            strategy_tag = str(action.payload.get("strategy_tag", ""))
            strategy_phase = str(action.payload.get("strategy_phase", ""))
            strategy_pair_signature = str(action.payload.get("strategy_pair_signature", ""))
            target_chain_id = str(action.payload.get("target_chain_id", ""))
            target_chain_cargo = str(action.payload.get("target_chain_cargo", "")).upper()
            return self._plan_shunt(
                candidate,
                shunt_signature,
                shunt_pair_signature,
                strategy_tag=strategy_tag,
                strategy_phase=strategy_phase,
                strategy_pair_signature=strategy_pair_signature,
                target_chain_id=target_chain_id,
                target_chain_cargo=target_chain_cargo,
            )

        chain = action.payload.get("chain", {})
        planning = action.payload.get("planning", {})
        target_chain_id = str(action.payload.get("target_chain_id", ""))
        target_chain_cargo = str(action.payload.get("target_chain_cargo", chain.get("final_cargo", ""))).upper()
        include_feeders = bool(action.payload.get("include_feeders", False))
        legs = chain.get("legs", [])
        feeder_legs = [leg for leg in legs if leg.get("type") != "processor_to_town"]
        delivery_transport = self._delivery_transport_for_chain(chain, planning=planning)
        rail_feeder_key = (
            self._select_rail_feeder_key(chain, feeder_legs, planning=planning)
            if include_feeders
            else None
        )
        seen = set()
        steps = []

        if include_feeders:
            # Optional mode for explicit recipe bootstraps; normal DAG-ready chain
            # execution should not rebuild feeder legs every cycle.
            for leg in feeder_legs:
                key = (
                    str(leg.get("source_id", "")),
                    str(leg.get("target_id", "")),
                    str(leg.get("cargo", "")),
                )
                if key in seen:
                    continue
                seen.add(key)
                transport_type = "rail" if rail_feeder_key and key == rail_feeder_key else "road"
                params = {
                    "industry1_id": str(leg.get("source_id", "")),
                    "industry2_id": str(leg.get("target_id", "")),
                    "transport_type": transport_type,
                    "cargo": str(leg.get("cargo", "")),
                }
                if transport_type == "rail":
                    params["double_track"] = "false"
                    params["expensive_mode"] = "false"
                steps.append(
                    {
                        "name": (
                            f"Build feeder {leg.get('source_name', '?')} -> "
                            f"{leg.get('target_name', '?')} ({leg.get('cargo', '?')}, {transport_type})"
                        ),
                        "command": "build_connection",
                        "params": params,
                        "wait_seconds": 20,
                    }
                )

        delivery_params = {
            "industry_id": str(chain.get("processor_id", "")),
            "town_id": str(chain.get("town_id", "")),
            "cargo": str(chain.get("final_cargo", "")),
            "transport_type": delivery_transport,
        }
        if delivery_transport == "rail":
            delivery_params["double_track"] = "false"
            delivery_params["expensive_mode"] = "false"

        steps.append(
            {
                "name": (
                    f"Build delivery {chain.get('processor', '?')} -> "
                    f"{chain.get('town', '?')} ({chain.get('final_cargo', '?')})"
                ),
                "command": "build_cargo_to_town",
                "params": delivery_params,
                "wait_seconds": 20,
            }
        )

        return {
            "name": f"Build {chain.get('final_cargo', '?')} to {chain.get('town', '?')}",
            "action": "build_chain",
            "steps": steps,
            "metadata": {
                "cargo": str(chain.get("final_cargo", "")),
                "town_id": str(chain.get("town_id", "")),
                "town_name": str(chain.get("town", "")),
                "processor": str(chain.get("processor", "")),
                "processor_id": str(chain.get("processor_id", "")),
                "transport_type": delivery_transport,
                "contains_rail": bool(delivery_transport == "rail" or (include_feeders and rail_feeder_key is not None)),
                "estimated_cost": _estimate_chain_cost(chain),
                "planning": planning,
                "target_chain_id": target_chain_id,
                "target_chain_cargo": target_chain_cargo,
            },
        }

    def _plan_multi_stop_loop(
        self,
        candidate: Dict[str, Any],
        town_ids: Set[str],
        loop_signature: str,
    ) -> Dict[str, Any]:
        steps = []
        seen = set()
        built_legs = 0
        cargo_set: Set[str] = set()
        town_name = ""

        for leg in candidate.get("legs", []):
            if not leg.get("loaded", False):
                continue
            if built_legs >= MAX_MULTI_STOP_BUILD_LEGS:
                break

            source_id = str(leg.get("source_id", ""))
            target_id = str(leg.get("target_id", ""))
            cargos = [str(c).upper() for c in leg.get("cargos", []) if str(c).strip()]
            cargo = self._choose_leg_cargo(cargos)
            if cargo:
                cargo_set.add(cargo)

            # Industry -> Town final delivery
            if target_id in town_ids and source_id not in town_ids:
                key = ("build_cargo_to_town", source_id, target_id, cargo)
                if key in seen:
                    continue
                seen.add(key)
                town_name = str(leg.get("target_name", town_name))
                steps.append(
                    {
                        "name": (
                            f"Build loop delivery {leg.get('source_name', '?')} -> "
                            f"{leg.get('target_name', '?')} ({cargo or 'AUTO'})"
                        ),
                        "command": "build_cargo_to_town",
                        "params": {
                            "industry_id": source_id,
                            "town_id": target_id,
                            "cargo": cargo or "GOODS",
                        },
                        "wait_seconds": 20,
                    }
                )
                built_legs += 1
                continue

            # Industry -> Industry feeder link
            if source_id not in town_ids and target_id not in town_ids:
                key = ("build_connection", source_id, target_id, cargo)
                if key in seen:
                    continue
                seen.add(key)
                params = {
                    "industry1_id": source_id,
                    "industry2_id": target_id,
                    "transport_type": "road",
                }
                if cargo:
                    params["cargo"] = cargo
                steps.append(
                    {
                        "name": (
                            f"Build loop feeder {leg.get('source_name', '?')} -> "
                            f"{leg.get('target_name', '?')} ({cargo or 'AUTO'})"
                        ),
                        "command": "build_connection",
                        "params": params,
                        "wait_seconds": 20,
                    }
                )
                built_legs += 1

        stops = candidate.get("stops", [])
        loop_name = " -> ".join(str(s.get("name", "?")) for s in stops)
        metadata = {
            "cargo": ",".join(sorted(cargo_set)),
            "town_id": "",
            "town_name": town_name,
            "processor": loop_name,
            "processor_id": "",
            "estimated_cost": _estimate_multi_stop_cost(candidate),
            "loop_signature": loop_signature,
            "loaded_distance_ratio": _to_float(candidate.get("loaded_distance_ratio", 0.0), 0.0),
            "loaded_leg_ratio": _to_float(candidate.get("loaded_leg_ratio", 0.0), 0.0),
            "loop_stop_count": _to_int(candidate.get("stop_count", 0), 0),
        }

        return {
            "name": f"Build multi-stop loop ({loop_name})",
            "action": "build_multi_stop_loop",
            "steps": steps,
            "metadata": metadata,
        }

    def _plan_shunt(
        self,
        candidate: Dict[str, Any],
        shunt_signature: str,
        shunt_pair_signature: str,
        strategy_tag: str = "",
        strategy_phase: str = "",
        strategy_pair_signature: str = "",
        target_chain_id: str = "",
        target_chain_cargo: str = "",
    ) -> Dict[str, Any]:
        source_id = str(candidate.get("source_id", ""))
        target_id = str(candidate.get("target_id", ""))
        cargo = str(candidate.get("cargo", "")).upper()
        transport_type = str(candidate.get("transport_type", "road"))
        step_params = {
            "industry1_id": source_id,
            "industry2_id": target_id,
            "transport_type": transport_type,
            "cargo": cargo,
        }
        if transport_type == "rail":
            step_params["double_track"] = "false"
            step_params["expensive_mode"] = "false"

        steps = []
        if (
            strategy_tag == "steel_payday"
            and strategy_phase.startswith("exchange_")
            and transport_type in {"rail", "water"}
        ):
            steps.append(
                {
                    "name": "Ensure steel intermodal transfer (pre-build)",
                    "command": "__ensure_steel_transfer__",
                    "params": {
                        "industry_ids": [source_id, target_id],
                        "max_distance": INTERMODAL_TRANSFER_MAX_DISTANCE_M,
                        "auto_build_rail": True,
                    },
                    "wait_seconds": 5,
                }
            )

        steps.append(
            {
                "name": (
                    f"Build shunt {candidate.get('source_name', '?')} -> "
                    f"{candidate.get('target_name', '?')} ({cargo}, {transport_type})"
                ),
                "command": "build_connection",
                "params": step_params,
                "wait_seconds": 20,
            }
        )
        if (
            strategy_tag == "steel_payday"
            and strategy_phase.startswith("exchange_")
            and transport_type in {"rail", "water"}
        ):
            steps.append(
                {
                    "name": "Ensure steel intermodal transfer (post-build)",
                    "command": "__ensure_steel_transfer__",
                    "params": {
                        "industry_ids": [source_id, target_id],
                        "max_distance": INTERMODAL_TRANSFER_MAX_DISTANCE_M,
                        "auto_build_rail": False,
                    },
                    "wait_seconds": 3,
                }
            )

        metadata = {
            "cargo": cargo,
            "town_id": "",
            "town_name": "",
            "processor": f"{candidate.get('source_name', '?')} -> {candidate.get('target_name', '?')}",
            "processor_id": target_id,
            "source_id": source_id,
            "source_name": str(candidate.get("source_name", "")),
            "target_id": target_id,
            "target_name": str(candidate.get("target_name", "")),
            "estimated_cost": _estimate_shunt_cost(
                _to_int(candidate.get("distance", 0), 0),
                transport_type,
            ),
            "shunt_signature": shunt_signature,
            "shunt_pair_signature": shunt_pair_signature,
            "strategy_tag": strategy_tag,
            "strategy_phase": strategy_phase,
            "strategy_pair_signature": strategy_pair_signature,
            "transport_type": transport_type,
            "contains_rail": bool(transport_type == "rail"),
            "chain_pull": _to_int(candidate.get("chain_pull", 0), 0),
            "target_chain_id": str(target_chain_id),
            "target_chain_cargo": str(target_chain_cargo).upper(),
        }

        return {
            "name": (
                f"Build shunt {candidate.get('source_name', '?')} -> "
                f"{candidate.get('target_name', '?')} ({cargo}, {transport_type})"
            ),
            "action": "build_shunt",
            "steps": steps,
            "metadata": metadata,
        }

    @staticmethod
    def _choose_leg_cargo(cargos: List[str]) -> str:
        if not cargos:
            return ""
        for cargo in cargos:
            if cargo in FINAL_GOODS:
                return cargo
        return cargos[0]


class Builder:
    def __init__(self, ipc, max_vehicle_add_per_line: int = 12, financial_guardian=None):
        self.ipc = ipc
        self.max_vehicle_add_per_line = max_vehicle_add_per_line
        self.financial_guardian = financial_guardian

    def execute(self, plan: Dict[str, Any], dry_run: bool = False) -> Dict[str, Any]:
        if plan.get("action") == "diagnose_line":
            return {
                "success": True,
                "action": "diagnose_line",
                "new_line_ids": [],
                "steps": [],
                "errors": [],
                "dry_run": bool(dry_run),
            }

        result = {
            "success": True,
            "action": plan.get("action"),
            "steps": [],
            "new_line_ids": [],
            "errors": [],
            "line_config": [],
            "dry_run": bool(dry_run),
        }

        lines_before = self._query_lines_map()
        known_line_ids = set(lines_before.keys())
        discovered_line_ids: Set[str] = set()

        for idx, step in enumerate(plan.get("steps", []), start=1):
            entry = {"step": idx, "name": step.get("name", ""), "ok": False}
            if dry_run:
                entry["ok"] = True
                entry["response"] = {"status": "ok", "data": "dry_run"}
                result["steps"].append(entry)
                continue

            command = str(step.get("command", ""))
            params = step.get("params", {})
            if command == "__ensure_steel_transfer__":
                resp = self._ensure_steel_transfer(params)
            else:
                resp = self.ipc.send(command, params, timeout=45.0)
            entry["response"] = resp
            if not resp or resp.get("status") != "ok":
                entry["ok"] = False
                result["steps"].append(entry)
                result["success"] = False
                result["errors"].append(
                    f"Step {idx} failed: {command} -> {resp}"
                )
                break

            entry["ok"] = True
            result["steps"].append(entry)
            wait_seconds = _to_int(step.get("wait_seconds", 0), 0)
            if wait_seconds > 0:
                time.sleep(wait_seconds)

            lines_after = self._query_lines_map()
            fresh_ids = set(lines_after.keys()) - known_line_ids
            if fresh_ids:
                discovered_line_ids |= fresh_ids
                known_line_ids |= fresh_ids

        result["new_line_ids"] = sorted(discovered_line_ids)

        if result["success"] and not dry_run:
            metadata = plan.get("metadata", {})
            transport_type = str(metadata.get("transport_type", "")).lower()
            contains_rail = bool(metadata.get("contains_rail", False))
            allow_scaling = (transport_type != "rail") and (not contains_rail)
            line_config: List[Dict[str, Any]] = []

            if result["new_line_ids"]:
                line_config.extend(
                    self._configure_new_lines(
                        result["new_line_ids"],
                        allow_scaling=allow_scaling,
                    )
                )

            if allow_scaling:
                existing_ids = self._find_matching_existing_line_ids(
                    metadata,
                    exclude_ids=set(result["new_line_ids"]),
                )
                if existing_ids:
                    line_config.extend(self._scale_existing_lines(existing_ids))

            result["line_config"] = line_config

        return result

    def _query_lines_map(self) -> Dict[str, Dict[str, Any]]:
        resp = self.ipc.send("query_lines")
        if not resp or resp.get("status") != "ok":
            return {}
        lines = resp.get("data", {}).get("lines", [])
        normalized = [_normalize_line(line) for line in lines]
        return {line["id"]: line for line in normalized if line.get("id")}

    def _configure_new_lines(
        self,
        line_ids: List[str],
        allow_scaling: bool = True,
    ) -> List[Dict[str, Any]]:
        records = []
        lines_map = self._query_lines_map()
        for line_id in line_ids:
            line_rec = {"line_id": line_id, "load_mode": False, "terminals": False, "added": 0}

            load_resp = self.ipc.send(
                "set_line_load_mode",
                {"line_id": str(line_id), "mode": "load_if_available"},
            )
            line_rec["load_mode"] = bool(load_resp and load_resp.get("status") == "ok")

            term_resp = self.ipc.send("set_line_all_terminals", {"line_id": str(line_id)})
            line_rec["terminals"] = bool(term_resp and term_resp.get("status") == "ok")

            line = lines_map.get(str(line_id))
            if line and allow_scaling:
                line_rec["added"] = self._scale_line_conservative(line)
            records.append(line_rec)
        return records

    def _find_matching_existing_line_ids(
        self,
        metadata: Dict[str, Any],
        exclude_ids: Optional[Set[str]] = None,
    ) -> List[str]:
        exclude = set(exclude_ids or set())
        source_name = str(metadata.get("source_name", "")).strip().lower()
        target_name = str(metadata.get("target_name", "")).strip().lower()
        cargo = str(metadata.get("cargo", "")).strip().upper()
        if not source_name or not target_name or not cargo:
            return []

        lines_map = self._query_lines_map()
        matches: List[str] = []
        for line_id, line in lines_map.items():
            if line_id in exclude:
                continue
            if str(line.get("transport_type", "unknown")).lower() != "road":
                continue
            if _to_int(line.get("vehicle_count", 0), 0) <= 0:
                continue
            line_name = str(line.get("name", ""))
            line_lc = line_name.lower()
            if source_name not in line_lc or target_name not in line_lc:
                continue
            known_cargos = _line_known_cargos(line)
            if cargo not in known_cargos and not _line_suffix_has_cargo(line_name, cargo):
                continue
            matches.append(line_id)
        return matches

    def _scale_existing_lines(self, line_ids: List[str]) -> List[Dict[str, Any]]:
        if not line_ids:
            return []
        records: List[Dict[str, Any]] = []
        lines_map = self._query_lines_map()
        for line_id in line_ids:
            line = lines_map.get(str(line_id))
            if not line:
                continue
            added = self._scale_line_conservative(line)
            records.append(
                {
                    "line_id": str(line_id),
                    "existing": True,
                    "load_mode": None,
                    "terminals": None,
                    "added": added,
                }
            )
        return records

    def _scale_line_conservative(self, line: Dict[str, Any]) -> int:
        is_rail = line.get("transport_type", "unknown") == "rail"

        vehicle_count = line.get("vehicle_count", 0)
        interval = line.get("interval", 0)
        if vehicle_count <= 0:
            resp = self.ipc.send("add_vehicle_to_line", {"line_id": str(line.get("id", ""))})
            return 1 if (resp and resp.get("status") == "ok") else 0
        if interval <= INITIAL_TARGET_INTERVAL_SECONDS:
            return 0

        needed = math.ceil(vehicle_count * (interval / INITIAL_TARGET_INTERVAL_SECONDS))
        to_add = max(0, needed - vehicle_count)
        # Rail lines: cap at 2 per pass (trains are expensive)
        max_add = 2 if is_rail else self.max_vehicle_add_per_line
        to_add = min(to_add, max_add)

        # Financial guard: check cash before buying vehicles
        if self.financial_guardian is not None:
            status = self.financial_guardian.get_financial_status()
            cash = status.get("cash", 0)
            year = status.get("year", 1900)
            budget_max = self.financial_guardian.vehicle_budget_for_line(cash, year)
            if budget_max <= 0:
                print(
                    f"[builder] Skipping vehicle scaling for line "
                    f"{line.get('id', '?')}: insufficient cash (${cash:,})"
                )
                return 0
            to_add = min(to_add, budget_max)

        added = 0
        for _ in range(to_add):
            resp = self.ipc.send("add_vehicle_to_line", {"line_id": str(line.get("id", ""))})
            if resp and resp.get("status") == "ok":
                added += 1
            else:
                break  # Stop on first failure (likely out of money)
        return added

    @staticmethod
    def _to_bool(value: Any, default: bool = False) -> bool:
        if isinstance(value, bool):
            return value
        if value is None:
            return default
        return str(value).strip().lower() in {"1", "true", "yes", "on"}

    @staticmethod
    def _station_mode(station: Dict[str, Any]) -> str:
        raw_type = str(station.get("type", "")).lower()
        name = str(station.get("name", "")).lower()
        if raw_type == "rail" or "rail" in name or "train" in name:
            return "rail"
        if raw_type in {"water", "ship"} or "harbor" in name or "port" in name:
            return "water"
        if raw_type == "road" or "truck" in name or "lorry" in name or "cargo" in name:
            return "road"
        if raw_type == "unknown":
            if "rail" in name or "train" in name:
                return "rail"
            if "harbor" in name or "port" in name:
                return "water"
            return "road"
        return "other"

    def _query_nearby_stations(self, industry_id: str, radius: int) -> List[Dict[str, Any]]:
        resp = self.ipc.send(
            "query_nearby_stations",
            {"industry_id": str(industry_id), "radius": int(radius)},
            timeout=15.0,
        )
        if not resp or resp.get("status") != "ok":
            return []
        stations = resp.get("data", {}).get("stations", [])
        if not isinstance(stations, list):
            return []
        return stations

    def _best_intermodal_gap(
        self,
        stations: List[Dict[str, Any]],
    ) -> Optional[Dict[str, Any]]:
        rails: List[Dict[str, Any]] = []
        roads: List[Dict[str, Any]] = []
        for station in stations:
            mode = self._station_mode(station)
            record = {
                "id": str(station.get("id", "")),
                "name": str(station.get("name", "")),
                "mode": mode,
                "x": _to_float(station.get("x", 0), 0.0),
                "y": _to_float(station.get("y", 0), 0.0),
                "distance": _to_int(station.get("distance", 0), 0),
            }
            if mode == "rail":
                rails.append(record)
            elif mode == "road":
                roads.append(record)
        if not rails or not roads:
            return None

        best: Optional[Dict[str, Any]] = None
        for rail in rails:
            for road in roads:
                dx = float(rail.get("x", 0.0)) - float(road.get("x", 0.0))
                dy = float(rail.get("y", 0.0)) - float(road.get("y", 0.0))
                gap = int(math.sqrt(dx * dx + dy * dy))
                if not best or gap < _to_int(best.get("gap", 999999), 999999):
                    best = {"gap": gap, "rail": rail, "road": road}
        return best

    def _ensure_industry_intermodal_ready(
        self,
        industry_id: str,
        max_gap_m: int,
        auto_build_rail: bool,
    ) -> Dict[str, Any]:
        stations = self._query_nearby_stations(industry_id, INTERMODAL_STATION_SCAN_RADIUS_M)
        best = self._best_intermodal_gap(stations)
        if best and _to_int(best.get("gap", 999999), 999999) <= max_gap_m:
            return {"status": "ok", "data": {"industry_id": str(industry_id), "gap": best.get("gap")}}

        if not auto_build_rail:
            return {
                "status": "error",
                "message": (
                    f"intermodal transfer gap too large at industry {industry_id}; "
                    f"required <= {max_gap_m}m"
                ),
            }

        build_resp = self.ipc.send(
            "build_rail_station",
            {
                "industry_id": str(industry_id),
                "name": f"Steel Transfer Rail {industry_id}",
                "distance": "20",
            },
            timeout=45.0,
        )
        if not build_resp or build_resp.get("status") != "ok":
            return {
                "status": "error",
                "message": f"build_rail_station failed for industry {industry_id}",
            }
        time.sleep(20)

        stations = self._query_nearby_stations(industry_id, INTERMODAL_STATION_SCAN_RADIUS_M)
        best = self._best_intermodal_gap(stations)
        if best and _to_int(best.get("gap", 999999), 999999) <= max_gap_m:
            return {"status": "ok", "data": {"industry_id": str(industry_id), "gap": best.get("gap")}}
        gap_label = _to_int(best.get("gap", 999999), 999999) if best else -1
        return {
            "status": "error",
            "message": (
                f"intermodal transfer still invalid at industry {industry_id} "
                f"(gap={gap_label}m, max={max_gap_m}m)"
            ),
        }

    def _ensure_steel_transfer(self, params: Dict[str, Any]) -> Dict[str, Any]:
        industry_ids = params.get("industry_ids", [])
        if isinstance(industry_ids, str):
            industry_ids = [piece.strip() for piece in industry_ids.split(",") if piece.strip()]
        if not isinstance(industry_ids, list) or len(industry_ids) < 2:
            return {"status": "error", "message": "Need at least 2 industry_ids for transfer check"}

        max_gap = max(50, _to_int(params.get("max_distance", INTERMODAL_TRANSFER_MAX_DISTANCE_M), INTERMODAL_TRANSFER_MAX_DISTANCE_M))
        auto_build_rail = self._to_bool(params.get("auto_build_rail", False), default=False)

        checks: List[Dict[str, Any]] = []
        for industry_id in industry_ids:
            check = self._ensure_industry_intermodal_ready(
                str(industry_id),
                max_gap_m=max_gap,
                auto_build_rail=auto_build_rail,
            )
            checks.append({"industry_id": str(industry_id), "result": check})
            if check.get("status") != "ok":
                return {
                    "status": "error",
                    "message": check.get("message", "intermodal transfer check failed"),
                    "data": {"checks": checks},
                }

        return {"status": "ok", "data": {"checks": checks, "max_gap": max_gap}}


class Verifier:
    def __init__(self, ipc):
        self.ipc = ipc

    def verify(self, plan: Dict[str, Any], build_result: Dict[str, Any], dry_run: bool = False) -> Dict[str, Any]:
        if dry_run:
            return {"success": build_result.get("success", False), "issues": [], "mode": "dry_run"}
        if not build_result.get("success", False):
            return {"success": False, "issues": build_result.get("errors", [])}

        issues = []
        lines_map = self._query_lines_map()
        for line_id in build_result.get("new_line_ids", []):
            line = lines_map.get(str(line_id))
            if not line:
                issues.append(f"line_missing:{line_id}")
                continue
            if line.get("vehicle_count", 0) == 0:
                issues.append(f"line_no_vehicle:{line_id}")
            if line.get("interval", 0) > 300:
                issues.append(f"line_high_interval:{line_id}")

        blocking = [
            issue for issue in issues
            if not str(issue).startswith("line_high_interval:")
        ]
        return {"success": len(blocking) == 0, "issues": issues}

    def _query_lines_map(self) -> Dict[str, Dict[str, Any]]:
        resp = self.ipc.send("query_lines")
        if not resp or resp.get("status") != "ok":
            return {}
        lines = resp.get("data", {}).get("lines", [])
        return {str(line.get("id", "")): _normalize_line(line) for line in lines}


class Learner:
    def __init__(self, memory: MemoryStore):
        self.memory = memory

    def record(
        self,
        cycle: int,
        action: Optional[Action],
        plan: Optional[Dict[str, Any]],
        build_result: Optional[Dict[str, Any]],
        verification: Optional[Dict[str, Any]],
    ) -> Optional[Dict[str, Any]]:
        if not action:
            return None

        metadata = (plan or {}).get("metadata", {})
        simulated = bool(
            (verification or {}).get("mode") == "dry_run"
            or (build_result or {}).get("dry_run", False)
        )
        build_ok = bool(build_result and build_result.get("success", False))
        verify_ok = bool(verification and verification.get("success", False))
        success = (build_ok and verify_ok) if not simulated else False

        record = {
            "timestamp": time.time(),
            "cycle": cycle,
            "action_type": action.action,
            "action": action.action,
            "priority": action.priority,
            "reason": action.reason,
            "cargo": metadata.get("cargo", ""),
            "town_id": metadata.get("town_id", ""),
            "town_name": metadata.get("town_name", ""),
            "processor": metadata.get("processor", ""),
            "loop_signature": metadata.get("loop_signature", ""),
            "shunt_signature": metadata.get("shunt_signature", ""),
            "shunt_pair_signature": metadata.get("shunt_pair_signature", ""),
            "strategy_tag": metadata.get("strategy_tag", ""),
            "strategy_phase": metadata.get("strategy_phase", ""),
            "strategy_pair_signature": metadata.get("strategy_pair_signature", ""),
            "target_chain_id": metadata.get("target_chain_id", ""),
            "target_chain_cargo": metadata.get("target_chain_cargo", ""),
            "success": success,
            "simulated": simulated,
            "new_line_ids": (build_result or {}).get("new_line_ids", []),
            "errors": (build_result or {}).get("errors", []) + (verification or {}).get("issues", []),
            "tags": self._tags_for(action, metadata, success, simulated),
        }
        return self.memory.add(record)

    @staticmethod
    def _tags_for(
        action: Action,
        metadata: Dict[str, Any],
        success: bool,
        simulated: bool,
    ) -> List[str]:
        tags = [action.action, "success" if success else "failure"]
        if simulated:
            tags.append("simulated")
        cargo = str(metadata.get("cargo", "")).upper()
        if cargo:
            tags.append(cargo)
        town = str(metadata.get("town_name", ""))
        if town:
            tags.append(f"town:{town}")
        loop_sig = str(metadata.get("loop_signature", ""))
        if loop_sig:
            tags.append(loop_sig)
        shunt_sig = str(metadata.get("shunt_signature", ""))
        if shunt_sig:
            tags.append(shunt_sig)
        shunt_pair_sig = str(metadata.get("shunt_pair_signature", ""))
        if shunt_pair_sig:
            tags.append(shunt_pair_sig)
        strategy_tag = str(metadata.get("strategy_tag", ""))
        if strategy_tag:
            tags.append(f"strategy:{strategy_tag}")
        strategy_phase = str(metadata.get("strategy_phase", ""))
        if strategy_phase:
            tags.append(strategy_phase)
        strategy_pair = str(metadata.get("strategy_pair_signature", ""))
        if strategy_pair:
            tags.append(strategy_pair)
        target_chain_id = str(metadata.get("target_chain_id", ""))
        if target_chain_id:
            tags.append(f"chain:{target_chain_id}")
        target_chain_cargo = str(metadata.get("target_chain_cargo", "")).upper()
        if target_chain_cargo:
            tags.append(f"chain_cargo:{target_chain_cargo}")
        return tags


class Orchestrator:
    def __init__(self, dry_run: bool = False, max_vehicle_add_per_line: int = 12):
        self.ipc = get_ipc()
        self.memory = MemoryStore()
        self.metrics = MetricsCollector(self.ipc, self.memory)
        self.dag_builder = DAGBuilder()
        self.surveyor = Surveyor(self.ipc, self.dag_builder)
        self.diagnostician = Diagnostician(self.memory)
        self.strategist = Strategist(self.memory, self.ipc)
        self.planner = Planner()
        self.financial_guardian = FinancialGuardian(self.ipc)
        self.line_doctor = LineDoctor()
        self.builder = Builder(
            self.ipc,
            max_vehicle_add_per_line=max_vehicle_add_per_line,
            financial_guardian=self.financial_guardian,
        )
        self.verifier = Verifier(self.ipc)
        self.learner = Learner(self.memory)
        self.dry_run = dry_run

    def _scale_undersupplied_lines(self, survey: Dict[str, Any]) -> int:
        """When no new chains to build, scale up undersupplied delivery lines.

        Finds active delivery lines with high intervals and adds vehicles.
        Returns number of lines scaled.
        """
        lines = survey.get("lines", [])
        if not lines:
            return 0

        # Find lines with high intervals that could use more vehicles
        scalable = []
        for line in lines:
            vehicle_count = _to_int(line.get("vehicle_count", 0), 0)
            interval = _to_float(line.get("interval", 0), 0)
            total_transported = _to_int(line.get("total_transported", 0), 0)
            rate = _to_float(line.get("rate", 0), 0)
            if vehicle_count <= 0:
                continue
            if total_transported == 0 and rate == 0:
                continue  # broken line, don't scale
            if interval <= INITIAL_TARGET_INTERVAL_SECONDS:
                continue  # already well-served
            scalable.append(line)

        if not scalable:
            return 0

        # Sort by interval (highest first — most undersupplied)
        scalable.sort(key=lambda l: _to_float(l.get("interval", 0), 0), reverse=True)

        scaled_count = 0
        for line in scalable[:5]:  # max 5 lines per cycle
            added = self.builder._scale_line_conservative(line)
            if added > 0:
                print(
                    f"[orchestrator] Scaled line '{line.get('name', '?')}' "
                    f"(id={line.get('id', '?')}): +{added} vehicles "
                    f"(interval was {_to_float(line.get('interval', 0), 0):.0f}s)"
                )
                scaled_count += 1
        return scaled_count

    def _ensure_calendar_speed(self) -> None:
        resp = self.ipc.send("set_calendar_speed", {"speed": TARGET_CALENDAR_SPEED})
        if not resp or resp.get("status") != "ok":
            print(
                f"[orchestrator] WARN: failed to set calendar speed "
                f"to {TARGET_CALENDAR_SPEED}"
            )

    @staticmethod
    def _describe_action_route(action: Action) -> str:
        payload = action.payload if isinstance(action.payload, dict) else {}
        if action.action == "build_shunt":
            cand = payload.get("candidate", {}) if isinstance(payload.get("candidate"), dict) else {}
            source = str(cand.get("source_name", "?"))
            target = str(cand.get("target_name", "?"))
            cargo = str(cand.get("cargo", "?")).upper()
            mode = str(cand.get("transport_type", "road")).lower()
            return f"{source} -> {target} ({cargo}, {mode})"
        if action.action == "build_chain":
            chain = payload.get("chain", {}) if isinstance(payload.get("chain"), dict) else {}
            processor = str(chain.get("processor", "?"))
            town = str(chain.get("town", "?"))
            cargo = str(chain.get("final_cargo", "?")).upper()
            return f"{processor} -> {town} ({cargo})"
        if action.action == "build_multi_stop_loop":
            candidate = payload.get("candidate", {}) if isinstance(payload.get("candidate"), dict) else {}
            stops = candidate.get("stops", []) if isinstance(candidate.get("stops"), list) else []
            if stops:
                return " -> ".join(str(stop.get("name", "?")) for stop in stops)
            return "multi-stop loop"
        if action.action == "diagnose_line":
            line_id = str(payload.get("line_id", "?"))
            line_name = str(payload.get("line_name", ""))
            return f"line {line_id} {line_name}".strip()
        return action.reason

    @staticmethod
    def _describe_executed_route(plan: Dict[str, Any]) -> str:
        metadata = plan.get("metadata", {}) if isinstance(plan.get("metadata"), dict) else {}
        source = str(metadata.get("source_name", ""))
        target = str(metadata.get("target_name", ""))
        cargo = str(metadata.get("cargo", "")).upper()
        mode = str(metadata.get("transport_type", "")).lower()
        if source and target and cargo:
            suffix = f", {mode}" if mode else ""
            return f"{source} -> {target} ({cargo}{suffix})"
        processor = str(metadata.get("processor", ""))
        town = str(metadata.get("town_name", ""))
        if processor and town and cargo:
            return f"{processor} -> {town} ({cargo})"
        steps = plan.get("steps", []) if isinstance(plan.get("steps"), list) else []
        if not steps:
            return plan.get("name", "")
        if len(steps) == 1:
            return str(steps[0].get("name", ""))
        first = str(steps[0].get("name", ""))
        return f"{first} ... (+{len(steps)-1} steps)"

    def run_cycle(self, cycle: int) -> Dict[str, Any]:
        self._ensure_calendar_speed()
        pre = self.metrics.collect()
        if not pre:
            return {"ok": False, "error": "metrics collection failed (pre)"}

        dashboard = self.metrics.get_dashboard()
        survey = self.surveyor.run(dashboard)
        if not survey.get("ok"):
            return {"ok": False, "error": survey.get("error", "surveyor failed")}

        # --- Emergency financial mode: cut costs instead of building ---
        if self.financial_guardian.is_emergency_mode():
            fin_status = self.financial_guardian.get_financial_status()
            print(
                f"[orchestrator] EMERGENCY MODE: cash=${fin_status['cash']:,} "
                f"level={fin_status['emergency_level']}"
            )
            cuts = self.financial_guardian.recommend_cost_cuts(
                survey.get("lines", [])
            )
            cuts_executed = 0
            for cut in cuts:
                lid = str(cut.get("line_id", ""))
                if cut["action"] == "delete":
                    self.line_doctor._delete_broken_line(self.ipc, lid)
                    cuts_executed += 1
                elif cut["action"] == "sell_vehicles":
                    count = int(cut.get("count", 1))
                    self.line_doctor._sell_excess_vehicles(
                        self.ipc, lid, keep_count=max(1, int(cut.get("keep", 1)))
                    )
                    cuts_executed += 1
            if cuts_executed > 0:
                self.metrics.collect()
                return {
                    "ok": True,
                    "idle": False,
                    "action": "emergency_cost_cut",
                    "reason": f"Emergency mode: {cuts_executed} cost cuts executed",
                    "money": fin_status["cash"],
                    "year": fin_status["year"],
                    "unserved_demands": len(survey.get("unserved_demands", [])),
                }

        # --- Periodic line cleanup (every 20 cycles) ---
        if cycle % 20 == 0:
            cleanup_actions = self.line_doctor.cleanup_unprofitable_lines(
                self.ipc, survey.get("lines", [])
            )
            if cleanup_actions:
                print(
                    f"[orchestrator] Line cleanup: {len(cleanup_actions)} actions"
                )

        # --- Diagnose and fix zero-transport lines ---
        diagnoses = self.diagnostician.run(
            survey,
            line_doctor=self.line_doctor,
            ipc=self.ipc,
        )

        # Filter out diagnoses where LineDoctor already handled the line
        # (fixed it, or it's just waiting in grace period — don't block building)
        active_diagnoses = [
            d for d in diagnoses
            if d.get("recommended_action") not in (
                "deleted", "selldown_to_1", "selldown_to_2",
                "waiting", "grace_period_started",
                "line is functional or empty",
            )
        ]
        action = self.strategist.choose_action(survey, active_diagnoses)
        if not action:
            # Fallback: scale undersupplied existing lines instead of sitting idle
            scaled = self._scale_undersupplied_lines(survey)
            self.metrics.collect()
            if scaled:
                return {
                    "ok": True,
                    "idle": False,
                    "action": "scale_existing",
                    "reason": f"Scaled {scaled} lines (no new chains to build)",
                    "money": survey.get("money"),
                    "year": survey.get("year"),
                    "unserved_demands": len(survey.get("unserved_demands", [])),
                    "build_success": True,
                    "verify_success": True,
                    "new_line_ids": [],
                    "verification_issues": [],
                    "diagnoses": len(diagnoses),
                }
            return {
                "ok": True,
                "idle": True,
                "reason": "no actionable opportunities",
                "money": survey.get("money"),
                "year": survey.get("year"),
                "unserved_demands": len(survey.get("unserved_demands", [])),
            }

        chosen_route = self._describe_action_route(action)
        mc_payload = action.payload.get("mc", {}) if isinstance(action.payload, dict) else {}
        mc_tier = (
            str(action.payload.get("mc_tier", ""))
            if isinstance(action.payload, dict)
            else ""
        )
        mc_sequence = (
            action.payload.get("mc_sequence", [])
            if isinstance(action.payload, dict) and isinstance(action.payload.get("mc_sequence", []), list)
            else []
        )
        mc_sequence_score = (
            _to_float(action.payload.get("mc_sequence_score", 0.0), 0.0)
            if isinstance(action.payload, dict)
            else 0.0
        )
        plan = self.planner.create_plan(action)
        executed_route = self._describe_executed_route(plan)
        build_result = self.builder.execute(plan, dry_run=self.dry_run)
        verification = self.verifier.verify(plan, build_result, dry_run=self.dry_run)
        self.learner.record(cycle, action, plan, build_result, verification)
        post = self.metrics.collect()
        if not post:
            return {"ok": False, "error": "metrics collection failed (post)"}

        return {
            "ok": True,
            "idle": False,
            "action": action.action,
            "reason": action.reason,
            "chosen_route": chosen_route,
            "executed_route": executed_route,
            "mc_tier": mc_tier,
            "mc_score": _to_float(mc_payload.get("score", 0.0), 0.0),
            "mc_util_p50": _to_float(mc_payload.get("utilization_p50", 0.0), 0.0),
            "mc_drawdown": _to_float(mc_payload.get("drawdown_prob", 0.0), 0.0),
            "mc_sequence": mc_sequence,
            "mc_sequence_score": mc_sequence_score,
            "plan_name": plan.get("name", ""),
            "steps": len(plan.get("steps", [])),
            "build_success": build_result.get("success", False),
            "verify_success": verification.get("success", False),
            "new_line_ids": build_result.get("new_line_ids", []),
            "verification_issues": verification.get("issues", []),
            "money": survey.get("money"),
            "year": survey.get("year"),
            "truck_utilization": _to_float(survey.get("truck_utilization", 0.0), 0.0),
            "unserved_demands": len(survey.get("unserved_demands", [])),
            "diagnoses": len(diagnoses),
        }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="TF2 multi-agent orchestrator loop")
    parser.add_argument(
        "--cycles",
        type=int,
        default=0,
        help="Number of cycles to run (0 = infinite, default: infinite)",
    )
    parser.add_argument(
        "--delay-seconds",
        type=int,
        default=30,
        help="Sleep time between cycles",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Plan actions without sending build commands",
    )
    parser.add_argument(
        "--max-vehicle-add-per-line",
        type=int,
        default=12,
        help="Cap vehicles added during scaling pass (higher helps reach ~60s truck interval)",
    )
    parser.add_argument(
        "--log-file",
        type=str,
        default=None,
        help="Path to log file (tees stdout to file and console)",
    )
    return parser.parse_args()


def _print_result(cycle: int, result: Dict[str, Any]) -> None:
    """Print cycle result in a consistent format."""
    year = result.get("year", "?")
    money = result.get("money", 0)
    money_str = f"${money:,}" if isinstance(money, (int, float)) else str(money)

    if not result.get("ok", False):
        print(f"[cycle {cycle}] ERROR year={year} {money_str}: {result.get('error')}")
    elif result.get("idle", False):
        print(
            f"[cycle {cycle}] IDLE year={year} {money_str} "
            f"unserved={result.get('unserved_demands')} reason={result.get('reason')}"
        )
    else:
        action = result.get("action", "?")
        print(
            f"[cycle {cycle}] year={year} {money_str} action={action} "
            f"build={result.get('build_success')} verify={result.get('verify_success')} "
            f"new_lines={len(result.get('new_line_ids', []))} "
            f"diag={result.get('diagnoses', 0)} unserved={result.get('unserved_demands')} "
            f"truck_util={result.get('truck_utilization', 0.0):.2f}"
        )
        chosen_route = result.get("chosen_route", "")
        if chosen_route:
            print(
                f"[cycle {cycle}] route={chosen_route} "
                f"tier={result.get('mc_tier', '')} "
                f"score={result.get('mc_score', 0.0):.1f} "
                f"util_p50={result.get('mc_util_p50', 0.0):.2f} "
                f"drawdown={result.get('mc_drawdown', 0.0):.2f}"
            )
        executed = result.get("executed_route", "")
        if executed:
            print(f"[cycle {cycle}] executed={executed}")
        sequence = result.get("mc_sequence", [])
        if sequence:
            print(
                f"[cycle {cycle}] plan={ ' | '.join(sequence) } "
                f"plan_score={result.get('mc_sequence_score', 0.0):.1f}"
            )
        issues = result.get("verification_issues", [])
        if issues:
            print(f"[cycle {cycle}] verify_issues: {', '.join(issues)}")


class _Tee:
    """Duplicate stdout to both console and a log file (stdlib only)."""

    def __init__(self, log_path: str):
        self._file = open(log_path, "a", buffering=1)  # line-buffered
        self._stdout = sys.stdout

    def write(self, data: str) -> int:
        self._stdout.write(data)
        self._file.write(data)
        return len(data)

    def flush(self) -> None:
        self._stdout.flush()
        self._file.flush()

    def fileno(self) -> int:
        return self._stdout.fileno()


def main() -> int:
    args = _parse_args()

    if args.log_file:
        sys.stdout = _Tee(args.log_file)
        sys.stderr = _Tee(args.log_file)

    ipc = get_ipc()

    # Wait indefinitely for TF2 IPC connection
    attempt = 0
    while not ipc.ping():
        attempt += 1
        wait = min(30, 10 * attempt)
        print(
            f"[startup] Waiting for TF2 IPC (attempt {attempt}), "
            f"retrying in {wait}s... Start the game with the mod enabled."
        )
        time.sleep(wait)
    print(f"[startup] TF2 IPC connected after {attempt} attempt(s).")

    start_speed = ipc.send("set_calendar_speed", {"speed": TARGET_CALENDAR_SPEED})
    if not start_speed or start_speed.get("status") != "ok":
        print(
            f"[startup] WARN: unable to set calendar speed to "
            f"{TARGET_CALENDAR_SPEED}"
        )

    orchestrator = Orchestrator(
        dry_run=args.dry_run,
        max_vehicle_add_per_line=max(0, args.max_vehicle_add_per_line),
    )

    cycle = 1
    consecutive_errors = 0
    consecutive_idles = 0
    base_delay = max(0, args.delay_seconds)

    print(f"[startup] Orchestrator running (cycles={'infinite' if args.cycles == 0 else args.cycles}, "
          f"delay={base_delay}s, dry_run={args.dry_run})")

    while True:
        try:
            result = orchestrator.run_cycle(cycle)
            _print_result(cycle, result)

            if not result.get("ok", False):
                consecutive_errors += 1
                consecutive_idles = 0
            elif result.get("idle", False):
                consecutive_idles += 1
                consecutive_errors = 0
            else:
                consecutive_errors = 0
                consecutive_idles = 0

        except Exception as exc:
            consecutive_errors += 1
            consecutive_idles = 0
            print(f"[cycle {cycle}] EXCEPTION ({type(exc).__name__}): {exc}")

        # Print dashboard every 10 cycles
        if cycle % 10 == 0:
            try:
                dashboard_text = orchestrator.metrics.get_dashboard_text()
                if dashboard_text:
                    print(f"\n{'='*60}")
                    print(dashboard_text)
                    print(f"{'='*60}\n")
            except Exception:
                pass

        # Print line doctor summary every 20 cycles
        if cycle % 20 == 0:
            try:
                diag_summary = orchestrator.line_doctor.get_diagnosis_summary()
                if diag_summary:
                    print(f"[line_doctor] Tracking {len(diag_summary)} broken lines")
            except Exception:
                pass

        # Check for game completion (year >= 2025)
        try:
            gs = ipc.send("query_game_state", {})
            if gs and gs.get("status") == "ok":
                game_year = _to_int(gs.get("data", {}).get("year", 0), 0)
                if game_year >= 2025:
                    print(f"[orchestrator] Game year {game_year} reached. Domination complete!")
                    break
        except Exception:
            pass

        if args.cycles > 0 and cycle >= args.cycles:
            break

        # Adaptive delay: backoff on errors/idles, reset on success
        if consecutive_errors >= 5:
            delay = 120
            print(f"[orchestrator] {consecutive_errors} consecutive errors, backing off {delay}s")
            # Try to re-ping IPC in case game restarted
            if not ipc.ping():
                print("[orchestrator] IPC lost, waiting for game to come back...")
                for attempt in range(30):
                    time.sleep(10)
                    if ipc.ping():
                        print("[orchestrator] IPC restored!")
                        consecutive_errors = 0
                        break
                else:
                    print("[orchestrator] IPC not restored after 5 minutes, exiting")
                    return 1
        elif consecutive_idles >= 5:
            delay = min(base_delay + consecutive_idles * 10, 120)
        else:
            delay = base_delay

        cycle += 1
        time.sleep(delay)

    print(f"[orchestrator] Finished after {cycle} cycles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
