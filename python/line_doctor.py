"""Line health management - diagnose and fix broken transport lines."""

import time
from typing import Dict, List, Optional


class LineDoctor:
    """Diagnoses and fixes broken transport lines."""

    # Grace periods in seconds
    GRACE_PERIOD = 600        # 10 min before first action
    SELLDOWN_2_PERIOD = 600   # 10 min: sell to 2 vehicles
    SELLDOWN_1_PERIOD = 1200  # 20 min: sell to 1 vehicle
    DELETE_PERIOD = 1800      # 30 min: delete line

    def __init__(self):
        self._diagnosis_tracker: Dict[str, Dict] = {}
        # line_id -> {"first_seen": float, "last_action": str, "action_time": float}

    def diagnose_and_fix(self, ipc, line: Dict, survey: Dict) -> Dict:
        """Analyze a zero-transport line and take corrective action.

        Decision logic:
        - First detection: log it, set grace timer (10 minutes)
        - After 10 min zero transport: sell down to 2 vehicles
        - After 20 min: sell down to 1 vehicle
        - After 30 min: delete the line entirely

        Returns dict with: line_id, action_taken, details
        """
        line_id = str(line.get("id", ""))
        line_name = line.get("name", "unknown")
        vehicle_count = int(line.get("vehicle_count", 0))
        total_transported = int(line.get("total_transported", 0))
        rate = float(line.get("rate", 0))
        now = time.time()

        result = {"line_id": line_id, "action_taken": "none", "details": ""}

        # Check if line is actually broken (vehicles present but nothing moving)
        is_broken = vehicle_count > 0 and total_transported == 0 and rate == 0

        if not is_broken:
            # Line is working or has no vehicles - clear tracking if present
            if line_id in self._diagnosis_tracker:
                print(f"[line_doctor] Line '{line_name}' (id={line_id}) recovered, clearing diagnosis tracker")
                del self._diagnosis_tracker[line_id]
            result["details"] = "line is functional or empty"
            return result

        # Line is broken - track it
        if line_id not in self._diagnosis_tracker:
            self._diagnosis_tracker[line_id] = {
                "first_seen": now,
                "last_action": "detected",
                "action_time": now,
            }
            print(f"[line_doctor] First detection of broken line '{line_name}' (id={line_id}), "
                  f"vehicles={vehicle_count}, starting grace period")
            result["action_taken"] = "grace_period_started"
            result["details"] = f"broken line detected, waiting {self.GRACE_PERIOD}s before action"
            return result

        tracker = self._diagnosis_tracker[line_id]
        elapsed = now - tracker["first_seen"]

        # Escalating response based on how long the line has been broken
        if elapsed >= self.DELETE_PERIOD:
            # 30+ min broken - delete entirely
            print(f"[line_doctor] Line '{line_name}' (id={line_id}) broken for {elapsed:.0f}s, deleting")
            success = self._delete_broken_line(ipc, line_id)
            if success:
                tracker["last_action"] = "deleted"
                tracker["action_time"] = now
                del self._diagnosis_tracker[line_id]
                result["action_taken"] = "deleted"
                result["details"] = f"line deleted after {elapsed:.0f}s broken"
            else:
                result["action_taken"] = "delete_failed"
                result["details"] = "IPC delete command failed"

        elif elapsed >= self.SELLDOWN_1_PERIOD and vehicle_count > 1:
            # 20+ min broken - sell down to 1
            print(f"[line_doctor] Line '{line_name}' (id={line_id}) broken for {elapsed:.0f}s, "
                  f"selling down to 1 vehicle (has {vehicle_count})")
            sold = self._sell_excess_vehicles(ipc, line_id, keep_count=1)
            tracker["last_action"] = "selldown_to_1"
            tracker["action_time"] = now
            result["action_taken"] = "selldown_to_1"
            result["details"] = f"sold {sold} vehicles, keeping 1"

        elif elapsed >= self.SELLDOWN_2_PERIOD and vehicle_count > 2:
            # 10+ min broken - sell down to 2
            print(f"[line_doctor] Line '{line_name}' (id={line_id}) broken for {elapsed:.0f}s, "
                  f"selling down to 2 vehicles (has {vehicle_count})")
            sold = self._sell_excess_vehicles(ipc, line_id, keep_count=2)
            tracker["last_action"] = "selldown_to_2"
            tracker["action_time"] = now
            result["action_taken"] = "selldown_to_2"
            result["details"] = f"sold {sold} vehicles, keeping 2"

        else:
            # Still in grace period or already sold down enough
            remaining = self.GRACE_PERIOD - elapsed if elapsed < self.GRACE_PERIOD else 0
            print(f"[line_doctor] Line '{line_name}' (id={line_id}) broken for {elapsed:.0f}s, "
                  f"vehicles={vehicle_count}, waiting ({remaining:.0f}s until next action)")
            result["action_taken"] = "waiting"
            result["details"] = (f"broken for {elapsed:.0f}s, vehicles={vehicle_count}, "
                                 f"last_action={tracker['last_action']}")

        return result

    def cleanup_unprofitable_lines(self, ipc, lines: List[Dict], min_age_seconds: int = 1800) -> List[Dict]:
        """Scan ALL lines for persistently broken ones and clean them up.

        A line is considered broken if:
        - vehicle_count > 0 AND total_transported == 0 AND rate == 0
        - Has been in this state for > min_age_seconds

        Actions:
        - >30 min broken with >3 vehicles: sell down to 1
        - >45 min broken: delete entirely

        Returns list of actions taken.
        """
        actions = []
        now = time.time()

        for line in lines:
            line_id = str(line.get("id", ""))
            line_name = line.get("name", "unknown")
            vehicle_count = int(line.get("vehicle_count", 0))
            total_transported = int(line.get("total_transported", 0))
            rate = float(line.get("rate", 0))

            is_broken = vehicle_count > 0 and total_transported == 0 and rate == 0
            if not is_broken:
                # Clear tracker if line recovered
                if line_id in self._diagnosis_tracker:
                    del self._diagnosis_tracker[line_id]
                continue

            # Track if not already tracked
            if line_id not in self._diagnosis_tracker:
                self._diagnosis_tracker[line_id] = {
                    "first_seen": now,
                    "last_action": "detected",
                    "action_time": now,
                }
                continue

            elapsed = now - self._diagnosis_tracker[line_id]["first_seen"]

            if elapsed < min_age_seconds:
                continue

            if elapsed >= 2700 and vehicle_count >= 1:
                # 45+ min broken - delete
                print(f"[line_doctor] Cleanup: deleting line '{line_name}' (id={line_id}), "
                      f"broken for {elapsed:.0f}s")
                success = self._delete_broken_line(ipc, line_id)
                if success:
                    del self._diagnosis_tracker[line_id]
                actions.append({
                    "line_id": line_id,
                    "line_name": line_name,
                    "action": "deleted" if success else "delete_failed",
                    "elapsed_seconds": elapsed,
                })

            elif elapsed >= min_age_seconds and vehicle_count > 3:
                # 30+ min broken with >3 vehicles - sell down to 1
                print(f"[line_doctor] Cleanup: selling vehicles on line '{line_name}' (id={line_id}), "
                      f"broken for {elapsed:.0f}s, vehicles={vehicle_count}")
                sold = self._sell_excess_vehicles(ipc, line_id, keep_count=1)
                self._diagnosis_tracker[line_id]["last_action"] = "cleanup_selldown"
                self._diagnosis_tracker[line_id]["action_time"] = now
                actions.append({
                    "line_id": line_id,
                    "line_name": line_name,
                    "action": "selldown_to_1",
                    "vehicles_sold": sold,
                    "elapsed_seconds": elapsed,
                })

        if actions:
            print(f"[line_doctor] Cleanup pass: {len(actions)} actions taken")
        return actions

    def _sell_excess_vehicles(self, ipc, line_id: str, keep_count: int = 1) -> int:
        """Sell vehicles down to keep_count. Returns number sold."""
        # Query current vehicle count for this line
        resp = ipc.send("query_lines", {})
        if not resp or resp.get("status") != "ok":
            print(f"[line_doctor] Failed to query lines for vehicle count")
            return 0

        current_count = 0
        for line in resp.get("data", {}).get("lines", []):
            if str(line.get("id", "")) == str(line_id):
                current_count = int(line.get("vehicle_count", 0))
                break

        to_sell = current_count - keep_count
        if to_sell <= 0:
            return 0

        resp = ipc.send("remove_vehicles_from_line", {
            "line_id": str(line_id),
            "count": str(to_sell),
        })

        if resp and resp.get("status") == "ok":
            print(f"[line_doctor] Sold {to_sell} vehicles from line {line_id} (kept {keep_count})")
            return to_sell
        else:
            print(f"[line_doctor] Failed to sell vehicles from line {line_id}: {resp}")
            return 0

    def _delete_broken_line(self, ipc, line_id: str) -> bool:
        """Delete a line entirely. Returns True on success."""
        resp = ipc.send("delete_line", {
            "line_id": str(line_id),
        })

        if resp and resp.get("status") == "ok":
            print(f"[line_doctor] Deleted line {line_id}")
            return True
        else:
            print(f"[line_doctor] Failed to delete line {line_id}: {resp}")
            return False

    def get_diagnosis_summary(self) -> Dict:
        """Return summary of all tracked diagnoses for logging."""
        now = time.time()
        summary = {}
        for line_id, tracker in self._diagnosis_tracker.items():
            elapsed = now - tracker["first_seen"]
            summary[line_id] = {
                "elapsed_seconds": round(elapsed),
                "last_action": tracker["last_action"],
                "seconds_since_action": round(now - tracker["action_time"]),
            }
        return summary
