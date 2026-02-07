"""
Metrics Collector - Tracks game performance over time.

Snapshots money, line health, and town supply each cycle.
Computes trends (money rate, delivery health, broken chains)
and renders a text dashboard for the LLM strategist prompt.

Usage:
    from metrics import MetricsCollector
    mc = MetricsCollector(ipc, memory)
    mc.collect()
    print(mc.get_dashboard_text())
"""

import json
import os
import time
from collections import deque
from pathlib import Path
from typing import Dict, List, Optional

METRICS_FILE = Path(__file__).parent / 'memory' / 'metrics_history.json'
MAX_SNAPSHOTS = 50


class MetricsCollector:
    """Collects and analyzes game performance metrics over time."""

    def __init__(self, ipc, memory=None):
        """
        Args:
            ipc: IPCClient instance
            memory: Optional MemoryStore instance for chain health cross-ref
        """
        self.ipc = ipc
        self.memory = memory
        self.snapshots = deque(maxlen=MAX_SNAPSHOTS)
        self._load_history()

    def collect(self) -> Optional[dict]:
        """Take a snapshot of current game state. Returns the snapshot or None on error."""
        snapshot = {
            'timestamp': time.time(),
            'money': None,
            'year': None,
            'lines': [],
            'town_supply': {},
        }

        # Game state (money, year)
        game_resp = self.ipc.send('query_game_state')
        if not game_resp or game_resp.get('status') != 'ok':
            return None
        data = game_resp.get('data', {})
        snapshot['money'] = int(data.get('money', '0'))
        snapshot['year'] = data.get('year', '0')

        # Lines
        lines_resp = self.ipc.send('query_lines')
        if lines_resp and lines_resp.get('status') == 'ok':
            for line in lines_resp.get('data', {}).get('lines', []):
                snapshot['lines'].append({
                    'id': line.get('id', ''),
                    'name': line.get('name', ''),
                    'vehicle_count': int(line.get('vehicle_count', '0')),
                    'frequency': line.get('frequency', ''),
                    'rate': line.get('rate', '0'),
                    'cargo': line.get('cargo', ''),
                    'transported': line.get('transported', {}),
                    'total_transported': int(line.get('total_transported', '0')),
                })

        # Town supply
        supply_resp = self.ipc.send('query_town_supply')
        if supply_resp and supply_resp.get('status') == 'ok':
            for town in supply_resp.get('data', {}).get('towns', []):
                town_id = town.get('id', '')
                town_name = town.get('name', '')
                cargos = {}
                for c in town.get('cargos', []):
                    cargos[c['cargo']] = {
                        'supply': int(c.get('supply', '0')),
                        'limit': int(c.get('limit', '0')),
                        'demand': int(c.get('demand', '0')),
                    }
                snapshot['town_supply'][town_id] = {
                    'name': town_name,
                    'cargos': cargos,
                }

        self.snapshots.append(snapshot)
        self._save_history()
        return snapshot

    def get_dashboard(self) -> dict:
        """Compute dashboard metrics from recent snapshots."""
        if not self.snapshots:
            return {
                'money_rate': None,
                'money_trend': 'unknown',
                'current_money': None,
                'line_health': {'healthy': 0, 'sick': 0, 'dead': 0, 'total': 0},
                'town_deliveries': [],
                'broken_deliveries': [],
                'chain_health': [],
            }

        latest = self.snapshots[-1]
        dashboard = {
            'current_money': latest['money'],
            'current_year': latest['year'],
        }

        # Money rate ($/min) from last few snapshots
        dashboard.update(self._compute_money_rate())

        # Line health from latest snapshot
        dashboard['line_health'] = self._compute_line_health(latest)

        # Town delivery trends
        deliveries, broken = self._compute_delivery_trends()
        dashboard['town_deliveries'] = deliveries
        dashboard['broken_deliveries'] = broken

        # Chain health (cross-ref with memory)
        dashboard['chain_health'] = self._compute_chain_health(latest)

        return dashboard

    def get_dashboard_text(self) -> str:
        """Render dashboard as human-readable text for LLM prompt."""
        d = self.get_dashboard()
        lines = []
        lines.append("=== METRICS DASHBOARD ===")

        # Money
        money = d.get('current_money')
        if money is not None:
            lines.append(f"Money: ${money:,}  Year: {d.get('current_year', '?')}")
            rate = d.get('money_rate')
            trend = d.get('money_trend', 'unknown')
            if rate is not None:
                lines.append(f"Money rate: ${rate:+,.0f}/min ({trend})")
        else:
            lines.append("Money: unknown")

        # Line health
        lh = d.get('line_health', {})
        zt = lh.get('zero_transport', 0)
        zt_str = f", {zt} zero-transport" if zt > 0 else ""
        lines.append(
            f"Lines: {lh.get('total', 0)} total "
            f"({lh.get('healthy', 0)} healthy, "
            f"{lh.get('sick', 0)} sick, "
            f"{lh.get('dead', 0)} dead{zt_str})"
        )

        # Town deliveries
        deliveries = d.get('town_deliveries', [])
        if deliveries:
            lines.append(f"Active deliveries ({len(deliveries)}):")
            for td in deliveries[:10]:
                trend_sym = {'increasing': '+', 'stable': '=', 'decreasing': '-'}.get(
                    td['trend'], '?'
                )
                lines.append(
                    f"  [{trend_sym}] {td['town']}: {td['cargo']} "
                    f"supply={td['current_supply']}/{td['limit']}"
                )

        # Broken deliveries
        broken = d.get('broken_deliveries', [])
        if broken:
            lines.append(f"BROKEN deliveries ({len(broken)}):")
            for bd in broken[:10]:
                lines.append(
                    f"  [!] {bd['town']}: {bd['cargo']} "
                    f"supply={bd['current_supply']}/{bd['limit']} "
                    f"(expected from decision #{bd.get('decision_id', '?')})"
                )

        # Chain health
        ch = d.get('chain_health', [])
        if ch:
            lines.append(f"Chain health ({len(ch)}):")
            for c in ch[:10]:
                status = c.get('status', 'unknown')
                emoji = {'healthy': 'OK', 'degraded': '!!', 'dead': 'XX', 'unknown': '??'}
                lines.append(
                    f"  [{emoji.get(status, '??')}] decision #{c['decision_id']}: "
                    f"{c['cargo']} -> {c['town']} ({status})"
                )

        return '\n'.join(lines)

    # --- Internal computations ---

    def _compute_money_rate(self) -> dict:
        """Compute money rate ($/min) from snapshots."""
        if len(self.snapshots) < 2:
            return {'money_rate': None, 'money_trend': 'unknown'}

        # Use oldest and newest snapshots for rate
        oldest = self.snapshots[0]
        newest = self.snapshots[-1]
        dt = newest['timestamp'] - oldest['timestamp']
        if dt < 1:
            return {'money_rate': None, 'money_trend': 'unknown'}

        dm = newest['money'] - oldest['money']
        rate_per_min = (dm / dt) * 60

        if rate_per_min > 1000:
            trend = 'growing'
        elif rate_per_min > -1000:
            trend = 'stable'
        else:
            trend = 'declining'

        return {'money_rate': rate_per_min, 'money_trend': trend}

    def _compute_line_health(self, snapshot: dict) -> dict:
        """Categorize lines as healthy/sick/dead/zero_transport."""
        healthy = 0
        sick = 0
        dead = 0
        zero_transport = 0

        # Build set of recently-built line IDs (grace period)
        recent_line_ids = set()
        if self.memory:
            now = time.time()
            for dec in self.memory.get_all():
                if now - dec.get('timestamp', 0) < 300:
                    for lid in dec.get('new_line_ids', []):
                        recent_line_ids.add(str(lid))

        for line in snapshot.get('lines', []):
            vc = line.get('vehicle_count', 0)
            if vc == 0:
                dead += 1
                continue
            # Check if line has vehicles but zero cargo moved
            # Use both total_transported AND rate to avoid false positives
            # in year 1 (yearly counters haven't accumulated yet)
            total_transported = line.get('total_transported', 0)
            line_rate = 0
            try:
                line_rate = float(line.get('rate', 0))
            except (ValueError, TypeError):
                pass
            line_id = str(line.get('id', ''))
            if vc > 0 and total_transported == 0 and line_rate == 0 and line_id not in recent_line_ids:
                zero_transport += 1
                continue
            freq = line.get('frequency', '')
            try:
                freq_val = float(str(freq).strip())
                interval = 1.0 / freq_val if freq_val > 0 else 9999
            except (ValueError, ZeroDivisionError):
                interval = 9999
            if interval <= 120:
                healthy += 1
            else:
                sick += 1
        return {
            'healthy': healthy, 'sick': sick, 'dead': dead,
            'zero_transport': zero_transport,
            'total': healthy + sick + dead + zero_transport,
        }

    def _compute_delivery_trends(self) -> tuple:
        """Detect which towns are receiving cargo (supply trending up) vs not.

        Returns:
            (active_deliveries, broken_deliveries)
        """
        active = []
        broken = []

        if len(self.snapshots) < 2:
            # With only one snapshot, report current supply levels
            latest = self.snapshots[-1] if self.snapshots else None
            if latest:
                for tid, tinfo in latest.get('town_supply', {}).items():
                    for cargo, vals in tinfo.get('cargos', {}).items():
                        if vals['supply'] > 0:
                            active.append({
                                'town': tinfo['name'],
                                'town_id': tid,
                                'cargo': cargo,
                                'current_supply': vals['supply'],
                                'limit': vals['limit'],
                                'trend': 'unknown',
                            })
            return active, broken

        oldest = self.snapshots[0]
        latest = self.snapshots[-1]

        # Compare supply values between oldest and latest
        for tid, tinfo in latest.get('town_supply', {}).items():
            old_town = oldest.get('town_supply', {}).get(tid, {})
            old_cargos = old_town.get('cargos', {})
            for cargo, vals in tinfo.get('cargos', {}).items():
                cur_supply = vals['supply']
                limit = vals['limit']
                old_supply = old_cargos.get(cargo, {}).get('supply', 0)

                if cur_supply == 0 and old_supply == 0:
                    continue  # Never had supply, skip

                diff = cur_supply - old_supply
                if diff > 0:
                    trend = 'increasing'
                elif diff == 0:
                    trend = 'stable'
                else:
                    trend = 'decreasing'

                active.append({
                    'town': tinfo['name'],
                    'town_id': tid,
                    'cargo': cargo,
                    'current_supply': cur_supply,
                    'limit': limit,
                    'trend': trend,
                })

        # Cross-reference with memory to find broken deliveries
        # Skip decisions made less than 5 minutes ago — supply chains
        # need time for cargo to flow through the production pipeline
        if self.memory:
            now = time.time()
            decisions = self.memory.get_all()
            for dec in decisions:
                if not dec.get('success'):
                    continue
                # Grace period: don't flag recent builds as broken
                decision_age = now - dec.get('timestamp', 0)
                if decision_age < 300:  # 5 minutes
                    continue
                town_id = str(dec.get('town_id', ''))
                cargo = dec.get('cargo', '')
                if not town_id or not cargo:
                    continue

                # Check if this town+cargo has supply increasing
                town_supply = latest.get('town_supply', {}).get(town_id, {})
                town_cargos = town_supply.get('cargos', {})
                cargo_data = town_cargos.get(cargo, {})
                cur_supply = cargo_data.get('supply', 0)

                # Check if lines from this decision still exist
                line_ids = dec.get('new_line_ids', [])
                live_line_ids = {str(l['id']) for l in latest.get('lines', [])}
                lines_alive = any(str(lid) in live_line_ids for lid in line_ids)

                if not lines_alive or cur_supply == 0:
                    broken.append({
                        'town': dec.get('town_name', town_supply.get('name', '?')),
                        'town_id': town_id,
                        'cargo': cargo,
                        'current_supply': cur_supply,
                        'limit': cargo_data.get('limit', 0),
                        'decision_id': dec.get('id', '?'),
                        'lines_alive': lines_alive,
                    })

        return active, broken

    def _compute_chain_health(self, latest: dict) -> list:
        """Cross-reference decisions with live state to assess chain health."""
        if not self.memory:
            return []

        results = []
        now = time.time()
        decisions = self.memory.get_all()
        live_line_ids = {str(l['id']) for l in latest.get('lines', [])}
        live_lines_with_vehicles = {
            str(l['id']) for l in latest.get('lines', [])
            if l.get('vehicle_count', 0) > 0
        }

        for dec in decisions:
            if not dec.get('success'):
                continue
            # Grace period: don't assess chains less than 5 min old
            if now - dec.get('timestamp', 0) < 300:
                continue

            line_ids = [str(lid) for lid in dec.get('new_line_ids', [])]
            if not line_ids:
                continue

            town_id = str(dec.get('town_id', ''))
            cargo = dec.get('cargo', '')

            # Check lines exist and have vehicles
            lines_exist = sum(1 for lid in line_ids if lid in live_line_ids)
            lines_active = sum(1 for lid in line_ids if lid in live_lines_with_vehicles)

            # Check town supply
            town_supply = latest.get('town_supply', {}).get(town_id, {})
            cargo_supply = town_supply.get('cargos', {}).get(cargo, {}).get('supply', 0)

            if lines_active == len(line_ids) and cargo_supply > 0:
                status = 'healthy'
            elif lines_active > 0:
                status = 'degraded'
            else:
                status = 'dead'

            results.append({
                'decision_id': dec.get('id', '?'),
                'cargo': cargo,
                'town': dec.get('town_name', '?'),
                'town_id': town_id,
                'status': status,
                'lines_total': len(line_ids),
                'lines_exist': lines_exist,
                'lines_active': lines_active,
                'town_supply': cargo_supply,
            })

        return results

    # --- Persistence ---

    def _load_history(self):
        """Load previous snapshots from disk."""
        if not METRICS_FILE.exists():
            return
        try:
            with open(METRICS_FILE, 'r') as f:
                data = json.load(f)
            if isinstance(data, list):
                for snap in data[-MAX_SNAPSHOTS:]:
                    self.snapshots.append(snap)
        except (json.JSONDecodeError, IOError):
            pass

    def _save_history(self):
        """Persist snapshots to disk."""
        METRICS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = METRICS_FILE.with_suffix('.json.tmp')
        with open(tmp, 'w') as f:
            json.dump(list(self.snapshots), f, indent=2)
        os.replace(str(tmp), str(METRICS_FILE))
