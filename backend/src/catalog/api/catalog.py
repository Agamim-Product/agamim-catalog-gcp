"""In-memory catalog snapshot: search, filters, facets and paging over gold data."""

from __future__ import annotations

import re
import threading
import time
import unicodedata
from collections import Counter
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any

from catalog.api.source import GoldData, GoldSource, Row

_NIQQUD = re.compile(r"[֑-ׇ]")  # Hebrew vowel points and cantillation marks


def normalize(text: str | None) -> str:
    """Lower-case, strip Hebrew niqqud and accents, and collapse spaces, for forgiving search."""
    if not text:
        return ""
    text = _NIQQUD.sub("", unicodedata.normalize("NFKD", text))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join(text.lower().split())


def _dataset_haystack(d: Row) -> str:
    org = d.get("organization") or {}
    parts: list[str | None] = [d.get("title"), d.get("name"), d.get("description"), org.get("title")]
    parts += list(d.get("tags") or [])
    for r in d.get("resources") or []:
        parts += [r.get("name"), r.get("format")]
        parts += [c.get("name") for c in r.get("columns") or []]
    return normalize(" ".join(p for p in parts if p))


def _flight_haystack(f: Row) -> str:
    keys = ("airline_code", "flight_number", "airline_name", "airport_code", "airport_name", "city_en",
            "country_en", "status_en")  # fmt: skip
    code = f"{f.get('airline_code') or ''}{f.get('flight_number') or ''}"
    return normalize(" ".join([code, *(str(f.get(k) or "") for k in keys)]))


@dataclass
class Snapshot:
    data: GoldData
    loaded_at: float
    marker: str | None
    by_name: dict[str, Row] = field(init=False)
    haystack: dict[str, str] = field(init=False)
    flight_haystack: list[str] = field(init=False)

    def __post_init__(self) -> None:
        self.by_name = {d["name"]: d for d in self.data.datasets}
        self.haystack = {d["name"]: _dataset_haystack(d) for d in self.data.datasets}
        self.flight_haystack = [_flight_haystack(f) for f in self.data.flights]


def _matches(haystack: str, query: str) -> bool:
    return all(term in haystack for term in normalize(query).split())


def page(items: list[Row], page_no: int, size: int) -> dict[str, Any]:
    start = (page_no - 1) * size
    return {"items": items[start : start + size], "total": len(items), "page": page_no, "size": size}


class Catalog:
    """Thread-safe holder of the current snapshot; reloads when the gold-ready marker changes."""

    def __init__(
        self, source: GoldSource, *, check_every_s: float = 60.0, clock: Callable[[], float] = time.time
    ) -> None:
        self._source = source
        self._check_every_s = check_every_s
        self._clock = clock
        self._lock = threading.Lock()
        self._snapshot: Snapshot | None = None
        self._last_check = 0.0

    def snapshot(self) -> Snapshot:
        now = self._clock()
        with self._lock:
            if self._snapshot is None:
                self._snapshot = self._load(now)
            elif now - self._last_check >= self._check_every_s:
                self._last_check = now
                marker = self._source.marker()
                if marker != self._snapshot.marker:
                    self._snapshot = self._load(now, marker)
            return self._snapshot

    def _load(self, now: float, marker: str | None = None) -> Snapshot:
        marker = marker if marker is not None else self._source.marker()
        self._last_check = now
        return Snapshot(data=self._source.load(), loaded_at=now, marker=marker)

    # ---- datasets ----
    def search(
        self, *, q: str = "", org: str = "", tag: str = "", fmt: str = "", sort: str = "title"
    ) -> list[Row]:
        snap = self.snapshot()
        out = []
        for d in snap.data.datasets:
            if q and not _matches(snap.haystack[d["name"]], q):
                continue
            if org and (d.get("organization") or {}).get("name") != org:
                continue
            if tag and tag not in (d.get("tags") or []):
                continue
            if fmt and fmt.upper() not in {(r.get("format") or "").upper() for r in d.get("resources") or []}:
                continue
            out.append(d)
        if sort == "modified":
            out.sort(key=lambda d: d.get("source_modified_at") or "", reverse=True)
        else:
            out.sort(key=lambda d: normalize(d.get("title")))
        return out

    def dataset(self, name: str) -> Row | None:
        return self.snapshot().by_name.get(name)

    def facets(self) -> dict[str, list[dict[str, Any]]]:
        snap = self.snapshot()
        orgs: Counter[tuple[str, str]] = Counter()
        tags: Counter[str] = Counter()
        formats: Counter[str] = Counter()
        for d in snap.data.datasets:
            o = d.get("organization") or {}
            if o.get("name"):
                orgs[(o["name"], o.get("title") or o["name"])] += 1
            tags.update(d.get("tags") or [])
            formats.update({(r.get("format") or "").upper() for r in d.get("resources") or []} - {""})
        return {
            "organizations": [{"value": k[0], "label": k[1], "count": n} for k, n in orgs.most_common()],
            "tags": [{"value": k, "label": k, "count": n} for k, n in tags.most_common(50)],
            "formats": [{"value": k, "label": k, "count": n} for k, n in formats.most_common()],
        }

    def suggest(self, q: str, limit: int = 6) -> list[Row]:
        if len(normalize(q)) < 2:
            return []
        hits = self.search(q=q)[:limit]
        return [
            {
                "name": d["name"],
                "title": d["title"],
                "organization": (d.get("organization") or {}).get("title"),
            }
            for d in hits
        ]

    # ---- table rows ----
    def resource(self, resource_id: str) -> tuple[Row, Row] | None:
        for d in self.snapshot().data.datasets:
            for r in d.get("resources") or []:
                if r["resource_id"] == resource_id:
                    return d, r
        return None

    def rows(self, resource_id: str, *, q: str = "") -> list[Row]:
        rows = self.snapshot().data.rows_by_resource.get(resource_id, [])
        if not q:
            return rows
        return [r for r in rows if _matches(normalize(" ".join(str(v) for v in r.values())), q)]

    # ---- flights ----
    def flights(self, *, q: str = "", direction: str = "", status: str = "") -> list[Row]:
        snap = self.snapshot()
        out = []
        for f, hay in zip(snap.data.flights, snap.flight_haystack, strict=True):
            if direction and f.get("direction") != direction:
                continue
            if status and (f.get("status_en") or "").upper() != status.upper():
                continue
            if q and not _matches(hay, q):
                continue
            out.append(f)
        out.sort(key=lambda f: f.get("scheduled_at") or "")
        return out

    def flight_statuses(self) -> list[dict[str, Any]]:
        counts = Counter(f.get("status_en") or "" for f in self.snapshot().data.flights)
        return [{"value": en, "label": en, "count": n} for en, n in counts.most_common() if en]

    # ---- status ----
    def status(self) -> Row:
        snap = self.snapshot()
        runs: Iterable[Row] = snap.data.runs
        last = next(iter(runs), None)
        return {
            "last_run": last,
            "recent_runs": snap.data.runs[:10],
            "datasets": len(snap.data.datasets),
            "flights": len(snap.data.flights),
            "snapshot_loaded_at": snap.loaded_at,
        }

    def dataset_history(self, dataset_id: str) -> list[Row]:
        return self._source.dataset_history(dataset_id)
