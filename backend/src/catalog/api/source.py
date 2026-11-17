"""Where the API's data comes from: the gold schema in the environment's Azure SQL database.

The API never queries SQL per request. It loads a snapshot of gold into memory and reloads it when a new
pipeline run has finished (the latest run_id in gold.fct_ingestion_run, checked at most once a minute).
It signs in with the web app's managed identity (no password), through Microsoft's ODBC driver.
"""

from __future__ import annotations

import json
import struct
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Protocol

Row = dict[str, Any]

SQL_COPT_SS_ACCESS_TOKEN = 1256  # pyodbc connection attribute for an Entra ID access token
SQL_SCOPE = "https://database.windows.net/.default"


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
    """SQL values to JSON-friendly ones: times become ISO strings (stored as UTC)."""
    if isinstance(value, datetime):
        return value.isoformat() + ("Z" if value.tzinfo is None else "")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_plain(v) for v in value]
    return value


def _json(text: str | None, default: Any) -> Any:
    if not text:
        return default
    try:
        return json.loads(text)
    except ValueError:
        return default


def build_datasets(datasets: list[Row], orgs: list[Row], resources: list[Row]) -> list[Row]:
    """Shape the current gold rows into the catalog documents the API returns."""
    org_by_id = {o["organization_id"]: o for o in orgs}
    res_by_dataset: dict[str, list[Row]] = {}
    for r in sorted(resources, key=lambda r: (r.get("position") is None, r.get("position") or 0)):
        res_by_dataset.setdefault(r["dataset_id"], []).append(
            {
                "resource_id": r["resource_id"],
                "name": r.get("name"),
                "description": r.get("description"),
                "format": r.get("format"),
                "download_url": r.get("download_url"),
                "size_bytes": r.get("size_bytes"),
                "is_queryable": bool(r.get("is_queryable")),
                "update_frequency": r.get("update_frequency"),
                "data_modified_at": r.get("data_modified_at"),
                "columns": _json(r.get("columns_json"), None),
                "row_count": r.get("row_count"),
                "has_full_rows": None if r.get("has_full_rows") is None else bool(r.get("has_full_rows")),
                "copied_at": r.get("copied_at"),
                "schema_changed_at": r.get("schema_changed_at"),
            }
        )
    out = []
    for d in datasets:
        org = org_by_id.get(d.get("organization_id"), {})
        out.append(
            {
                "dataset_id": d["dataset_id"],
                "name": d["name"],
                "title": d.get("title"),
                "description": d.get("description"),
                "license": d.get("license"),
                "author": d.get("author"),
                "maintainer": d.get("maintainer"),
                "update_frequency": d.get("update_frequency"),
                "tags": _json(d.get("tags_json"), []),
                "source_created_at": d.get("source_created_at"),
                "source_modified_at": d.get("source_modified_at"),
                "source_url": d.get("source_url"),
                "catalog_changed_at": d.get("valid_from"),
                "organization": {
                    "id": org.get("organization_id"),
                    "name": org.get("name"),
                    "title": org.get("title"),
                    "image_url": org.get("image_url"),
                },
                "resources": res_by_dataset.get(d["dataset_id"], []),
            }
        )
    return _plain(out)  # type: ignore[no-any-return]


class AzureSqlGold:
    def __init__(self, server: str, database: str, *, connect: Callable[[], Any] | None = None) -> None:
        self._server = server
        self._database = database
        self._connect = connect or self._default_connect

    def _default_connect(self) -> Any:  # pragma: no cover - needs Azure; exercised by the deploy smoke test
        import pyodbc
        from azure.identity import DefaultAzureCredential

        drivers = [d for d in pyodbc.drivers() if "SQL Server" in d]
        if not drivers:
            raise RuntimeError("No Microsoft ODBC driver for SQL Server is installed")
        driver = sorted(drivers)[-1]
        token = DefaultAzureCredential().get_token(SQL_SCOPE).token.encode("utf-16-le")
        packed = struct.pack(f"<I{len(token)}s", len(token), token)
        conn_str = (
            f"Driver={{{driver}}};Server=tcp:{self._server},1433;Database={self._database};"
            "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30"
        )
        return pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: packed})

    @contextmanager
    def _cursor(self) -> Iterator[Any]:
        conn = self._connect()
        try:
            yield conn.cursor()
        finally:
            conn.close()

    def _query(self, sql: str, *params: Any) -> list[Row]:
        with self._cursor() as cur:
            cur.execute(sql, *params)
            names = [c[0] for c in cur.description]
            return [dict(zip(names, row, strict=True)) for row in cur.fetchall()]

    def marker(self) -> str | None:
        rows = self._query(
            "SELECT MAX(run_id) AS run_id FROM gold.fct_ingestion_run WHERE status = 'succeeded'"
        )
        value = rows[0]["run_id"] if rows else None
        return str(value) if value else None

    def load(self) -> GoldData:
        datasets = self._query("SELECT * FROM gold.dim_dataset WHERE is_current = 1")
        orgs = self._query("SELECT * FROM gold.dim_organization WHERE is_current = 1")
        resources = self._query(
            """SELECT r.*, s.columns_json, s.valid_from AS schema_changed_at,
                      snap.row_count, snap.has_full_rows, snap.copied_at
               FROM gold.dim_resource r
               LEFT JOIN gold.dim_resource_schema s ON s.resource_id = r.resource_id AND s.is_current = 1
               LEFT JOIN gold.resource_snapshot snap ON snap.resource_id = r.resource_id
               WHERE r.is_current = 1"""
        )
        flights = self._query(
            """SELECT flight_key, airline_code, flight_number, airline_name, direction, scheduled_at,
                      estimated_at,
                      airport_code, airport_name, city_en, city_he, country_en, country_he, terminal,
                      checkin_counters, checkin_zone, status_en, status_he, valid_from AS changed_at
               FROM gold.dim_flight WHERE is_current = 1"""
        )
        runs = self._query("SELECT TOP 20 * FROM gold.fct_ingestion_run ORDER BY run_id DESC")
        rows: dict[str, list[Row]] = {}
        for item in self._query(
            "SELECT resource_id, row_json FROM gold.resource_row ORDER BY resource_id, row_number"
        ):
            rows.setdefault(item["resource_id"], []).append(_json(item["row_json"], {}))
        return GoldData(
            datasets=build_datasets(datasets, orgs, resources),
            flights=_plain(flights),
            runs=_plain(runs),
            rows_by_resource=rows,
        )

    def dataset_history(self, dataset_id: str) -> list[Row]:
        rows = self._query(
            """SELECT 'dataset' AS kind, dataset_id AS id, title AS label, valid_from, valid_to, is_current,
                      (SELECT title, description, license, update_frequency, tags_json, source_modified_at
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS snapshot
               FROM gold.dim_dataset WHERE dataset_id = ?
               UNION ALL
               SELECT 'table_structure', s.resource_id, r.name, s.valid_from, s.valid_to, s.is_current,
                      CONCAT('{"columns":', s.columns_json, '}')
               FROM gold.dim_resource_schema s
               JOIN gold.dim_resource r ON r.resource_id = s.resource_id AND r.is_current = 1
               WHERE r.dataset_id = ?
               ORDER BY valid_from DESC
               OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY""",
            dataset_id,
            dataset_id,
        )
        for r in rows:
            r["is_current"] = bool(r["is_current"])
        return _plain(rows)  # type: ignore[no-any-return]

    def flight_history(self, flight_key: str) -> list[Row]:
        rows = self._query(
            """SELECT TOP 100 status_en, status_he, estimated_at, terminal, checkin_counters, valid_from,
                      valid_to,
                      is_current
               FROM gold.dim_flight WHERE flight_key = ? ORDER BY valid_from DESC""",
            flight_key,
        )
        for r in rows:
            r["is_current"] = bool(r["is_current"])
        return _plain(rows)  # type: ignore[no-any-return]
