from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from catalog.api.source import AzureSqlGold, build_datasets

T = datetime(2026, 11, 17, 12, 0, 0)


class FakeCursor:
    """Answers each SQL statement from a table of (substring -> rows)."""

    def __init__(
        self, answers: list[tuple[str, list[dict[str, Any]]]], log: list[tuple[str, tuple[Any, ...]]]
    ):
        self._answers = answers
        self._log = log
        self._rows: list[dict[str, Any]] = []
        self.description: list[tuple[str]] = []

    def execute(self, sql: str, *params: Any) -> None:
        self._log.append((sql, params))
        for needle, rows in self._answers:
            if needle in sql:
                self._rows = rows
                self.description = [(k,) for k in (rows[0].keys() if rows else ["x"])]
                return
        raise AssertionError(f"unexpected SQL: {sql[:80]}")

    def fetchall(self) -> list[tuple[Any, ...]]:
        return [tuple(r.values()) for r in self._rows]


class FakeConnection:
    def __init__(
        self, answers: list[tuple[str, list[dict[str, Any]]]], log: list[tuple[str, tuple[Any, ...]]]
    ):
        self._answers = answers
        self._log = log
        self.closed = False

    def cursor(self) -> FakeCursor:
        return FakeCursor(self._answers, self._log)

    def close(self) -> None:
        self.closed = True


DATASET = {
    "dataset_id": "d1", "name": "flydata", "title": "מאגר טיסות", "description": "תיאור", "organization_id": "o1",
    "license": "Other (Open)", "author": None, "maintainer": None, "update_frequency": "Times in day",
    "tags_json": '["תעופה"]', "resource_count": 1, "source_created_at": T, "source_modified_at": T,
    "source_url": "https://data.gov.il/dataset/flydata", "valid_from": T,
}  # fmt: skip
ORG = {"organization_id": "o1", "name": "iaa", "title": "רשות שדות התעופה", "image_url": None}
RESOURCE = {
    "resource_id": "r1", "dataset_id": "d1", "name": "טיסות", "description": None, "format": "CSV",
    "download_url": "https://x", "size_bytes": 10, "is_queryable": 1, "update_frequency": None, "position": 0,
    "data_modified_at": T, "columns_json": '[{"name":"CHOPER","type":"text","position":1}]',
    "schema_changed_at": T, "row_count": 2, "has_full_rows": 1, "copied_at": T,
}  # fmt: skip
FLIGHT = {"flight_key": "LY-1-arrival-x", "airline_code": "LY", "scheduled_at": T, "changed_at": T}


def make(
    answers: list[tuple[str, list[dict[str, Any]]]],
) -> tuple[AzureSqlGold, list[Any], list[FakeConnection]]:
    log: list[Any] = []
    conns: list[FakeConnection] = []

    def connect() -> FakeConnection:
        c = FakeConnection(answers, log)
        conns.append(c)
        return c

    return AzureSqlGold("srv", "gold", connect=connect), log, conns


def test_build_datasets_shapes_the_catalog_document() -> None:
    [doc] = build_datasets([DATASET], [ORG], [RESOURCE])
    assert doc["tags"] == ["תעופה"]
    assert doc["organization"] == {"id": "o1", "name": "iaa", "title": "רשות שדות התעופה", "image_url": None}
    assert doc["catalog_changed_at"] == "2026-11-17T12:00:00Z"
    [res] = doc["resources"]
    assert res["columns"] == [{"name": "CHOPER", "type": "text", "position": 1}]
    assert res["is_queryable"] is True
    assert res["has_full_rows"] is True


def test_build_datasets_tolerates_missing_and_bad_json() -> None:
    bad = {**DATASET, "tags_json": "not json", "organization_id": "missing"}
    [doc] = build_datasets([bad], [], [{**RESOURCE, "columns_json": None, "has_full_rows": None}])
    assert doc["tags"] == []
    assert doc["organization"]["id"] is None
    assert doc["resources"][0]["columns"] is None
    assert doc["resources"][0]["has_full_rows"] is None


def test_load_reads_current_gold_and_closes_connections() -> None:
    gold, log, conns = make(
        [
            ("FROM gold.dim_dataset WHERE is_current", [DATASET]),
            ("FROM gold.dim_organization", [ORG]),
            ("FROM gold.dim_resource r", [RESOURCE]),
            ("FROM gold.dim_flight WHERE is_current", [FLIGHT]),
            ("FROM gold.fct_ingestion_run ORDER BY", [{"run_id": "20261117120000", "status": "succeeded"}]),
            ("FROM gold.resource_row", [{"resource_id": "r1", "row_json": '{"_id": 1, "CHOPER": "LY"}'}]),
        ]
    )
    data = gold.load()
    assert data.datasets[0]["name"] == "flydata"
    assert data.flights[0]["scheduled_at"] == "2026-11-17T12:00:00Z"
    assert data.runs[0]["run_id"] == "20261117120000"
    assert data.rows_by_resource == {"r1": [{"_id": 1, "CHOPER": "LY"}]}
    assert all(c.closed for c in conns)
    assert len(log) == 6


def test_marker_is_latest_successful_run() -> None:
    gold, _, _ = make([("MAX(run_id)", [{"run_id": "20261117120000"}])])
    assert gold.marker() == "20261117120000"
    empty, _, _ = make([("MAX(run_id)", [{"run_id": None}])])
    assert empty.marker() is None


def test_histories_use_parameters_not_sql_text() -> None:
    gold, log, _ = make(
        [
            ("UNION ALL", [{"kind": "dataset", "id": "d1", "label": "x", "valid_from": T, "valid_to": None,
                            "is_current": 1, "snapshot": json.dumps({"title": "x"})}]),
            ("FROM gold.dim_flight WHERE flight_key = ?", [{"status_en": "LANDED", "valid_from": T, "is_current": 0}]),
        ]
    )  # fmt: skip
    hist = gold.dataset_history("d1'; DROP TABLE x;--")
    assert hist[0]["is_current"] is True
    assert log[0][1] == ("d1'; DROP TABLE x;--", "d1'; DROP TABLE x;--")
    flights = gold.flight_history("LY-1")
    assert flights[0]["is_current"] is False
    assert log[1][1] == ("LY-1",)
