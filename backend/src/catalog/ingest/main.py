"""Entry point for the Cloud Run Job `catalog-ingest`.

One run:
  1. reads the selected datasets (CKAN_DATASETS) with package_show, or every dataset with package_search
     when no list is set, and writes them unchanged to bronze (entity `package`);
  2. for datastore tables that changed since they were last fetched, reads the columns, the total and the
     rows (entity `datastore` for the columns and first rows, entity `records` for every row when full-row
     copying is on), all unchanged;
  3. writes a one-line `run` record last, which marks the run as complete for Dataform.

Settings come from environment variables (see Settings.from_env). Exit code 1 means the run must not be
transformed.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from catalog.ingest.bronze import ObjectStore, open_store, partition_key, to_ndjson
from catalog.ingest.ckan import SAMPLE_ROWS, CkanClient, JSONDict

log = logging.getLogger("catalog.ingest")

STATE_KEY = "_state/datastore.json"
NDJSON = "application/x-ndjson"


@dataclass(frozen=True)
class Settings:
    ckan_base_url: str
    bronze_uri: str
    run_id: str
    datasets: tuple[str, ...] = ()
    full_rows: bool = True
    max_rows_per_table: int = 200000
    max_datastore_calls: int = 3000
    min_interval_s: float = 0.2

    @staticmethod
    def from_env(now: datetime) -> Settings:
        datasets = tuple(d.strip() for d in os.environ.get("CKAN_DATASETS", "").split(",") if d.strip())
        return Settings(
            ckan_base_url=os.environ.get("CKAN_BASE_URL", "https://data.gov.il"),
            bronze_uri=os.environ["BRONZE_URI"],
            run_id=os.environ.get("RUN_ID") or now.strftime("%Y%m%dT%H%M%SZ"),
            datasets=datasets,
            full_rows=os.environ.get("FULL_ROWS", "true").lower() in {"1", "true", "yes"},
            max_rows_per_table=int(os.environ.get("MAX_ROWS_PER_TABLE", "200000")),
            max_datastore_calls=int(os.environ.get("MAX_DATASTORE_CALLS", "3000")),
            min_interval_s=float(os.environ.get("CKAN_MIN_INTERVAL_S", "0.2")),
        )


@dataclass
class RunStats:
    packages: int = 0
    resources: int = 0
    datastore_candidates: int = 0
    datastore_fetched: int = 0
    datastore_failed: int = 0
    datastore_pending: int = 0
    rows_fetched: int = 0
    failed_resource_ids: list[str] = field(default_factory=list)


def _version(resource: JSONDict) -> str:
    """What makes a stored copy stale: the table's data or its metadata changed."""
    return f"{resource.get('last_modified') or ''}|{resource.get('metadata_modified') or ''}"


def _load_state(store: ObjectStore) -> dict[str, str]:
    raw = store.read_text(STATE_KEY)
    if not raw:
        return {}
    data = json.loads(raw)
    return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}


def _fetch_packages(settings: Settings, client: CkanClient) -> list[JSONDict]:
    if settings.datasets:
        return [client.package_show(name) for name in settings.datasets]
    return list(client.iter_packages())


def run(settings: Settings, store: ObjectStore, client: CkanClient, now: datetime) -> RunStats:
    stats = RunStats()
    started = now

    packages = _fetch_packages(settings, client)
    if not packages:
        raise RuntimeError("CKAN returned no datasets; refusing to write an empty snapshot")
    stats.packages = len(packages)
    body, _ = to_ndjson(settings.run_id, datetime.now(UTC), ((p["id"], p) for p in packages))
    store.write_text(partition_key("package", settings.run_id, started), body, NDJSON)

    state = _load_state(store)
    candidates: list[JSONDict] = []
    for package in packages:
        for resource in package.get("resources") or []:
            stats.resources += 1
            if resource.get("datastore_active") and state.get(resource["id"]) != _version(resource):
                candidates.append(resource)
    stats.datastore_candidates = len(candidates)
    batch = candidates[: settings.max_datastore_calls]
    stats.datastore_pending = len(candidates) - len(batch)

    previews: list[tuple[str, Any]] = []
    rows: list[tuple[str, Any]] = []
    for resource in batch:
        rid = resource["id"]
        try:
            if settings.full_rows:
                table = client.datastore_rows(rid, max_rows=settings.max_rows_per_table)
            else:
                table = client.datastore_preview(rid)
        except Exception as exc:  # one broken table must not fail the run
            stats.datastore_failed += 1
            stats.failed_resource_ids.append(rid)
            log.warning("datastore_search failed for %s: %s", rid, exc)
            continue
        version = _version(resource)
        previews.append(
            (
                rid,
                {
                    "resource_id": rid,
                    "package_id": resource.get("package_id"),
                    "resource_version": version,
                    "fields": table["fields"],
                    "total": table["total"],
                    "records": table["records"][:SAMPLE_ROWS],
                    "full_rows": settings.full_rows,
                },
            )
        )
        if settings.full_rows:
            for record in table["records"]:
                rows.append((f"{rid}:{record.get('_id')}", {"resource_id": rid, "row": record}))
        state[rid] = version
    stats.datastore_fetched = len(previews)
    stats.rows_fetched = len(rows)

    body, _ = to_ndjson(settings.run_id, datetime.now(UTC), previews)
    store.write_text(partition_key("datastore", settings.run_id, started), body, NDJSON)
    body, _ = to_ndjson(settings.run_id, datetime.now(UTC), rows)
    store.write_text(partition_key("records", settings.run_id, started), body, NDJSON)
    store.write_text(STATE_KEY, json.dumps(state, sort_keys=True), "application/json")

    summary = {
        "run_id": settings.run_id,
        "source": settings.ckan_base_url,
        "datasets": list(settings.datasets) or ["*"],
        "started_at": started.isoformat(),
        "finished_at": datetime.now(UTC).isoformat(),
        "status": "succeeded",
        "packages": stats.packages,
        "resources": stats.resources,
        "datastore_candidates": stats.datastore_candidates,
        "datastore_fetched": stats.datastore_fetched,
        "datastore_failed": stats.datastore_failed,
        "datastore_pending": stats.datastore_pending,
        "rows_fetched": stats.rows_fetched,
        "failed_resource_ids": stats.failed_resource_ids[:50],
    }
    body, _ = to_ndjson(settings.run_id, datetime.now(UTC), [(settings.run_id, summary)])
    store.write_text(partition_key("run", settings.run_id, started), body, NDJSON)
    log.info(json.dumps({"message": "ingest finished", **summary}, ensure_ascii=False))
    return stats


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    now = datetime.now(UTC)
    settings = Settings.from_env(now)
    store = open_store(settings.bronze_uri)
    try:
        with CkanClient(settings.ckan_base_url, min_interval_s=settings.min_interval_s) as client:
            run(settings, store, client, now)
    except Exception:
        log.exception(json.dumps({"message": "ingest failed", "run_id": settings.run_id}))
        sys.exit(1)


if __name__ == "__main__":  # pragma: no cover
    main()
