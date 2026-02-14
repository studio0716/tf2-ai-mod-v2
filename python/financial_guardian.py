"""Financial guardian for TF2 AI mod - prevents bankruptcy during autonomous play."""

import math
import time
from typing import Dict, List, Optional


class FinancialGuardian:
    """Monitors financial health and enforces spending limits."""

    def __init__(self, ipc):
        self.ipc = ipc
        self._last_cash_samples: List[tuple] = []  # (timestamp, cash)
        self._max_samples = 20

    def get_financial_status(self) -> Dict:
        """Query game state and return financial snapshot.

        Returns dict with: cash, year, money_rate, emergency_level,
        max_build_spend, max_vehicle_spend.
        """
        try:
            resp = self.ipc.send("query_game_state", {})
            data = resp.get("data", {})
            cash = int(data.get("money", "0"))
            year = int(data.get("year", "1900"))
        except Exception as e:
            print(f"[financial] IPC error querying game state: {e}")
            # Safe defaults: assume broke so we don't overspend
            cash = 0
            year = 1900

        self._record_cash_sample(cash)
        money_rate = self._compute_money_rate()

        # Determine emergency level
        if cash < 500_000:
            emergency_level = "critical"
        elif cash < 1_000_000:
            emergency_level = "high"
        elif cash < 3_000_000 and money_rate < 0:
            emergency_level = "moderate"
        else:
            emergency_level = "normal"

        max_build_spend = max(0, int((cash - 500_000) * 0.40)) if cash > 500_000 else 0
        max_vehicle_spend = max(0, int(cash * 0.30))

        if emergency_level in ("critical", "high"):
            print(f"[financial] WARNING: emergency_level={emergency_level}, "
                  f"cash=${cash:,}, rate=${money_rate:,.0f}/min")

        return {
            "cash": cash,
            "year": year,
            "money_rate": money_rate,
            "emergency_level": emergency_level,
            "max_build_spend": max_build_spend,
            "max_vehicle_spend": max_vehicle_spend,
        }

    def is_emergency_mode(self) -> bool:
        """Returns True if cash situation requires cost-cutting instead of building."""
        status = self.get_financial_status()
        return status["emergency_level"] in ("critical", "high")

    def can_afford_vehicles(self, count: int, year: int = 1900) -> bool:
        """Check if buying count vehicles is within budget.

        Rule: never spend >30% of cash on vehicle scaling per cycle.
        """
        try:
            resp = self.ipc.send("query_game_state", {})
            cash = int(resp.get("data", {}).get("money", "0"))
        except Exception as e:
            print(f"[financial] IPC error in can_afford_vehicles: {e}")
            return False

        cost = count * self.estimated_vehicle_cost(year)
        budget = cash * 0.30
        if cost > budget:
            print(f"[financial] Vehicle purchase denied: {count} vehicles @ "
                  f"${self.estimated_vehicle_cost(year):,}/ea = ${cost:,} "
                  f"exceeds 30% budget ${budget:,.0f}")
            return False
        return True

    def can_afford_build(self, estimated_cost: int) -> bool:
        """Check if a build is within budget.

        Rule: never spend >40% of cash on single build. Keep $500K reserve.
        """
        try:
            resp = self.ipc.send("query_game_state", {})
            cash = int(resp.get("data", {}).get("money", "0"))
        except Exception as e:
            print(f"[financial] IPC error in can_afford_build: {e}")
            return False

        reserve = 500_000
        if cash < reserve:
            print(f"[financial] Build denied: cash ${cash:,} below ${reserve:,} reserve")
            return False

        budget = (cash - reserve) * 0.40
        if estimated_cost > budget:
            print(f"[financial] Build denied: ${estimated_cost:,} exceeds 40% budget "
                  f"${budget:,.0f} (cash=${cash:,}, reserve=${reserve:,})")
            return False
        return True

    def vehicle_budget_for_line(self, cash: int, year: int = 1900) -> int:
        """Max vehicles that can be added to one line this cycle.

        Formula: min(5, floor(cash * 0.30 / estimated_vehicle_cost(year)))
        """
        cost_per = self.estimated_vehicle_cost(year)
        if cost_per <= 0:
            return 0
        raw = math.floor(cash * 0.30 / cost_per)
        return max(0, min(5, raw))

    @staticmethod
    def estimated_vehicle_cost(year: int) -> int:
        """Approximate vehicle cost by era."""
        if year < 1920:
            return 100_000
        elif year < 1960:
            return 200_000
        elif year < 2000:
            return 400_000
        else:
            return 600_000

    def recommend_cost_cuts(self, lines: List[Dict]) -> List[Dict]:
        """In emergency mode, identify lines to downscale or delete.

        Priority order:
        1. Delete lines with zero transport + vehicles (bleeding cash)
        2. Sell vehicles from lines with vehicle_count > 15 and interval < 30s
        3. Sell vehicles from lines with vehicle_count > 8 and interval < 45s

        Args:
            lines: list of dicts with keys: id, name, vehicle_count,
                   total_transported, rate, interval

        Returns: list of {line_id, action, count, reason}
        """
        cuts: List[Dict] = []

        # Priority 1: delete zero-transport lines that have vehicles
        for line in lines:
            vehicle_count = int(line.get("vehicle_count", 0))
            total_transported = int(line.get("total_transported", 0))
            rate = float(line.get("rate", 0))
            if vehicle_count > 0 and total_transported == 0 and rate == 0:
                cuts.append({
                    "line_id": line["id"],
                    "action": "delete",
                    "count": vehicle_count,
                    "reason": f"Zero transport with {vehicle_count} vehicles "
                              f"(line: {line.get('name', '?')})",
                })

        # Priority 2: over-served lines with >15 vehicles and <30s interval
        for line in lines:
            vehicle_count = int(line.get("vehicle_count", 0))
            interval = float(line.get("interval", 999))
            if vehicle_count > 15 and interval < 30:
                sell_count = vehicle_count - 10  # bring down to 10
                cuts.append({
                    "line_id": line["id"],
                    "action": "sell_vehicles",
                    "count": sell_count,
                    "reason": f"Over-served: {vehicle_count} vehicles, "
                              f"{interval:.0f}s interval (line: {line.get('name', '?')})",
                })

        # Priority 3: moderately over-served lines with >8 vehicles and <45s interval
        for line in lines:
            vehicle_count = int(line.get("vehicle_count", 0))
            interval = float(line.get("interval", 999))
            # Skip if already recommended for deletion or priority 2 cut
            already_cut = any(c["line_id"] == line["id"] for c in cuts)
            if already_cut:
                continue
            if vehicle_count > 8 and interval < 45:
                sell_count = vehicle_count - 6  # bring down to 6
                cuts.append({
                    "line_id": line["id"],
                    "action": "sell_vehicles",
                    "count": sell_count,
                    "reason": f"Moderately over-served: {vehicle_count} vehicles, "
                              f"{interval:.0f}s interval (line: {line.get('name', '?')})",
                })

        if cuts:
            print(f"[financial] Recommending {len(cuts)} cost cuts:")
            for c in cuts:
                print(f"[financial]   {c['action']} line {c['line_id']}: {c['reason']}")

        return cuts

    def _compute_money_rate(self) -> float:
        """Compute $/minute from recent cash samples."""
        if len(self._last_cash_samples) < 2:
            return 0.0

        oldest_ts, oldest_cash = self._last_cash_samples[0]
        newest_ts, newest_cash = self._last_cash_samples[-1]

        elapsed_minutes = (newest_ts - oldest_ts) / 60.0
        if elapsed_minutes < 0.01:  # avoid division by near-zero
            return 0.0

        return (newest_cash - oldest_cash) / elapsed_minutes

    def _record_cash_sample(self, cash: int) -> None:
        """Add a cash sample with timestamp for rate computation."""
        self._last_cash_samples.append((time.time(), cash))
        if len(self._last_cash_samples) > self._max_samples:
            self._last_cash_samples = self._last_cash_samples[-self._max_samples:]
