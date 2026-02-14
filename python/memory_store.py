"""
Persistent memory store for orchestrator decisions and outcomes.

This is a lightweight JSON-backed store intended for:
- strategist lookups (what worked recently)
- metrics cross-reference (chain health / broken deliveries)
- operator inspection of prior actions
"""

import json
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


DEFAULT_MEMORY_FILE = Path(__file__).parent / "memory" / "decisions.json"
MAX_DECISIONS = 2000


class MemoryStore:
    """Simple append-oriented decision memory."""

    def __init__(
        self,
        path: Path = DEFAULT_MEMORY_FILE,
        max_records: int = MAX_DECISIONS,
    ):
        self.path = Path(path)
        self.max_records = max_records
        self._decisions: List[Dict[str, Any]] = []
        self._load()

    def get_all(self) -> List[Dict[str, Any]]:
        """Return all decisions in chronological order."""
        return list(self._decisions)

    def get_recent(self, limit: int = 20) -> List[Dict[str, Any]]:
        """Return the last N decisions."""
        if limit <= 0:
            return []
        return list(self._decisions[-limit:])

    def add(self, record: Dict[str, Any]) -> Dict[str, Any]:
        """Add and persist a decision record."""
        now = time.time()
        clean = dict(record or {})
        if "id" not in clean:
            clean["id"] = int(now * 1000)
        clean.setdefault("timestamp", now)
        clean.setdefault("tags", [])
        clean.setdefault("success", False)
        clean.setdefault("action_type", "")

        self._decisions.append(clean)
        if len(self._decisions) > self.max_records:
            self._decisions = self._decisions[-self.max_records:]
        self._save()
        return clean

    def find_similar(
        self,
        query: str,
        tags: Optional[List[str]] = None,
        limit: int = 5,
    ) -> List[Dict[str, Any]]:
        """Very simple lexical search over records + tags."""
        if limit <= 0:
            return []
        tokens = [t for t in re.split(r"[^a-z0-9_]+", query.lower()) if t]
        tags_lc = [t.lower() for t in (tags or [])]

        scored = []
        for rec in self._decisions:
            score = 0
            rec_tags = [str(t).lower() for t in rec.get("tags", [])]
            hay = self._record_text(rec).lower()
            for token in tokens:
                if token in hay:
                    score += 2
            for tag in tags_lc:
                if tag in rec_tags:
                    score += 3
            if score > 0:
                scored.append((score, rec.get("timestamp", 0), rec))

        scored.sort(key=lambda row: (row[0], row[1]), reverse=True)
        return [row[2] for row in scored[:limit]]

    def has_recent_success(
        self,
        cargo: str,
        town_id: str,
        window_seconds: int = 1800,
    ) -> bool:
        """Return True if this town+cargo has a recent successful build."""
        now = time.time()
        target_cargo = str(cargo or "").upper()
        target_town = str(town_id or "")
        if not target_cargo or not target_town:
            return False

        for rec in reversed(self._decisions):
            if not rec.get("success"):
                continue
            age = now - float(rec.get("timestamp", 0))
            if age > window_seconds:
                return False
            if str(rec.get("town_id", "")) != target_town:
                continue
            if str(rec.get("cargo", "")).upper() == target_cargo:
                return True
        return False

    def _load(self):
        if not self.path.exists():
            return
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, list):
                self._decisions = data[-self.max_records:]
        except (json.JSONDecodeError, OSError):
            self._decisions = []

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_suffix(".json.tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(self._decisions, f, indent=2)
        os.replace(str(tmp_path), str(self.path))

    @staticmethod
    def _record_text(record: Dict[str, Any]) -> str:
        parts = [
            record.get("action_type", ""),
            record.get("action", ""),
            record.get("reason", ""),
            record.get("cargo", ""),
            record.get("town_name", ""),
            record.get("processor", ""),
        ]
        lessons = record.get("lessons", [])
        if isinstance(lessons, list):
            parts.extend(str(x) for x in lessons)
        return " ".join(str(p) for p in parts if p is not None)
