"""Writes raw records to the bronze lake as newline-delimited JSON.

Layout (hive-partitioned so BigQuery can read it in place):
    <root>/ckan/<entity>/dt=YYYY-MM-DD/run=<run_id>/part-00000.ndjson

Every line is {"run_id", "fetched_at", "entity_id", "payload"}. The payload is the source record encoded
as a JSON string, so the lake never breaks when CKAN adds, removes or renames a field.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlparse


class ObjectStore(Protocol):
    def write_text(self, key: str, data: str, content_type: str) -> None: ...
    def read_text(self, key: str) -> str | None: ...


class LocalStore:
    """Filesystem store for local runs and tests (BRONZE_URI=file:///path)."""

    def __init__(self, root: Path) -> None:
        self.root = root

    def write_text(self, key: str, data: str, content_type: str) -> None:
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data, encoding="utf-8")

    def read_text(self, key: str) -> str | None:
        path = self.root / key
        return path.read_text(encoding="utf-8") if path.exists() else None


class GcsStore:
    """Cloud Storage store (BRONZE_URI=gs://bucket/optional/prefix)."""

    def __init__(self, bucket: str, prefix: str) -> None:
        from google.cloud import storage  # type: ignore[attr-defined]

        self._bucket = storage.Client().bucket(bucket)
        self._prefix = prefix.strip("/")

    def _name(self, key: str) -> str:
        return f"{self._prefix}/{key}" if self._prefix else key

    def write_text(self, key: str, data: str, content_type: str) -> None:
        blob = self._bucket.blob(self._name(key))
        blob.upload_from_string(data.encode("utf-8"), content_type=content_type)

    def read_text(self, key: str) -> str | None:
        blob = self._bucket.blob(self._name(key))
        if not blob.exists():
            return None
        text: str = blob.download_as_text(encoding="utf-8")
        return text


def open_store(uri: str) -> ObjectStore:
    parsed = urlparse(uri)
    if parsed.scheme == "gs":
        return GcsStore(parsed.netloc, parsed.path)
    if parsed.scheme == "file":
        return LocalStore(Path(parsed.path))
    raise ValueError(f"Unsupported BRONZE_URI scheme: {uri!r} (use gs:// or file://)")


def partition_key(entity: str, run_id: str, run_started: datetime) -> str:
    return f"ckan/{entity}/dt={run_started:%Y-%m-%d}/run={run_id}/part-00000.ndjson"


def to_ndjson(run_id: str, fetched_at: datetime, records: Iterable[tuple[str, Any]]) -> tuple[str, int]:
    lines = []
    stamp = fetched_at.isoformat()
    for entity_id, payload in records:
        lines.append(
            json.dumps(
                {
                    "run_id": run_id,
                    "fetched_at": stamp,
                    "entity_id": entity_id,
                    "payload": json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                },
                ensure_ascii=False,
            )
        )
    return ("\n".join(lines) + "\n" if lines else ""), len(lines)
