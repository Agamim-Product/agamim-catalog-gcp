"""Where the API's data comes from: gold tables in BigQuery, and the 'gold is ready' marker in the lake.

The API never queries BigQuery per request. It loads a snapshot of gold into memory and reloads it when the
marker written at the end of each refresh changes (checked at most once a minute). That keeps responses fast
and BigQuery use well inside the free tier.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlparse

Row = dict[str, Any]

# Project and dataset names come from deployment settings, never from requests; they are still checked,
# because they are placed in SQL text. Every request value is passed as a query parameter.
_IDENT = re.compile(r"[A-Za-z0-9_\-]{1,128}")


@dataclass(frozen=True)
class GoldData:
    datasets: list[Row]
    flights: list[Row]
    runs: list[Row]
    rows_by_resource: dict[str, list[Row]]


class GoldSource(Protocol):
    def marker(self) -> str | None:
        """An opaque value that changes whenever gold has been refreshed."""

    def load(self) -> GoldData: ...

    def dataset_history(self, dataset_id: str) -> list[Row]: ...

    def flight_history(self, flight_key: str) -> list[Row]: ...


def _plain(value: Any) -> Any:
    """BigQuery rows to JSON-friendly values (timestamps become ISO strings, JSON columns are parsed)."""
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_plain(v) for v in value]
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


class BigQueryGold:
    MAX_ROWS_PER_TABLE = 50000

    def __init__(self, project: str, dataset: str, location: str, marker_uri: str) -> None:
        from google.cloud import bigquery, storage  # type: ignore[attr-defined]

        for name in (project, dataset):
            if not _IDENT.fullmatch(name):
                raise ValueError(f"Invalid BigQuery identifier: {name!r}")
        self._bq = bigquery.Client(project=project, location=location)
        self._ds = f"`{project}.{dataset}`"
        parsed = urlparse(marker_uri)
        self._marker_blob = (
            storage.Client(project=project).bucket(parsed.netloc).blob(parsed.path.lstrip("/"))
        )

    def _query(self, sql: str, params: list[Any] | None = None) -> list[Row]:
        from google.cloud import bigquery

        config = bigquery.QueryJobConfig(query_parameters=params or [], use_query_cache=True)
        return [_plain(dict(row.items())) for row in self._bq.query(sql, job_config=config).result()]

    def marker(self) -> str | None:
        from google.api_core.exceptions import NotFound

        try:
            self._marker_blob.reload()
        except NotFound:
            return None
        return str(self._marker_blob.generation)

    def load(self) -> GoldData:
        datasets = self._query(f"SELECT * FROM {self._ds}.v_catalog")
        flights = self._query(
            f"""SELECT * EXCEPT (row_hash, is_current, valid_to, run_id), valid_from AS changed_at
                FROM {self._ds}.dim_flight WHERE is_current"""
        )
        runs = self._query(f"SELECT * FROM {self._ds}.fct_ingestion_run ORDER BY run_id DESC LIMIT 20")
        rows: dict[str, list[Row]] = {}
        for item in self._query(
            f"""SELECT resource_id, row_number, TO_JSON_STRING(row) AS row FROM {self._ds}.resource_row
                QUALIFY ROW_NUMBER() OVER (PARTITION BY resource_id ORDER BY row_number)
                        <= {self.MAX_ROWS_PER_TABLE}
                ORDER BY resource_id, row_number"""
        ):
            rows.setdefault(item["resource_id"], []).append(json.loads(item["row"]))
        return GoldData(datasets=datasets, flights=flights, runs=runs, rows_by_resource=rows)

    def dataset_history(self, dataset_id: str) -> list[Row]:
        from google.cloud import bigquery

        return self._query(
            f"""SELECT 'dataset' AS kind, dataset_id AS id, title AS label, valid_from, valid_to, is_current,
                       TO_JSON_STRING(STRUCT(title, description, license, update_frequency, tags,
                                             source_modified_at)) AS snapshot
                FROM {self._ds}.dim_dataset WHERE dataset_id = @id
                UNION ALL
                SELECT 'table_structure', s.resource_id, r.name, s.valid_from, s.valid_to, s.is_current,
                       TO_JSON_STRING(STRUCT(s.columns))
                FROM {self._ds}.dim_resource_schema s
                JOIN {self._ds}.dim_resource r ON r.resource_id = s.resource_id AND r.is_current
                WHERE r.dataset_id = @id
                ORDER BY valid_from DESC
                LIMIT 200""",
            [bigquery.ScalarQueryParameter("id", "STRING", dataset_id)],
        )

    def flight_history(self, flight_key: str) -> list[Row]:
        from google.cloud import bigquery

        return self._query(
            f"""SELECT status_en, status_he, estimated_at, terminal, checkin_counters, valid_from, valid_to,
                       is_current
                FROM {self._ds}.dim_flight WHERE flight_key = @key ORDER BY valid_from DESC LIMIT 100""",
            [bigquery.ScalarQueryParameter("key", "STRING", flight_key)],
        )
