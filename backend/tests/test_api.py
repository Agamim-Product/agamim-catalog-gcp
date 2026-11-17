from __future__ import annotations

from typing import Any

import pytest
from fastapi.testclient import TestClient

from catalog.api.app import create_app
from catalog.api.catalog import Catalog, normalize
from catalog.api.source import GoldData, _plain

FLIGHTS_ID = "res-flights"


def dataset(
    name: str, title: str, org: tuple[str, str], *, tags: list[str], fmt: str, modified: str
) -> dict[str, Any]:
    return {
        "dataset_id": f"id-{name}",
        "name": name,
        "title": title,
        "description": f"תיאור של {title}",
        "tags": tags,
        "source_modified_at": modified,
        "organization": {"id": f"org-{org[0]}", "name": org[0], "title": org[1], "image_url": None},
        "resources": [
            {
                "resource_id": FLIGHTS_ID if name == "flydata" else f"res-{name}",
                "name": "קובץ",
                "format": fmt,
                "position": 0,
                "columns": [{"name": "CHOPER", "type": "text", "position": 1}],
                "row_count": 2,
            }
        ],
    }


DATASETS = [
    dataset("flydata", "מאגר טיסות", ("iaa", "רשות שדות התעופה"), tags=["תעופה"], fmt="CSV", modified="2026-11-16T20:00:00"),
    dataset("shelters", "מִקְלָטִים", ("br7", "עיריית באר שבע"), tags=["חירום"], fmt="XLSX", modified="2026-01-01T00:00:00"),
]  # fmt: skip

FLIGHTS = [
    {"flight_key": "LY-001-departure-x", "airline_code": "LY", "flight_number": "001", "airline_name": "EL AL",
     "direction": "departure", "city_en": "NEW YORK", "city_he": "ניו יורק", "status_en": "ON TIME",
     "status_he": "בזמן", "scheduled_at": "2026-11-17T10:00:00"},
    {"flight_key": "W6-002-arrival-x", "airline_code": "W6", "flight_number": "002", "airline_name": "WIZZ",
     "direction": "arrival", "city_en": "ROME", "city_he": "רומא", "status_en": "LANDED", "status_he": "נחתה",
     "scheduled_at": "2026-11-17T08:00:00"},
]  # fmt: skip


class FakeSource:
    def __init__(self) -> None:
        self.loads = 0
        self.current_marker: str | None = "1"
        self.datasets = DATASETS

    def marker(self) -> str | None:
        return self.current_marker

    def load(self) -> GoldData:
        self.loads += 1
        return GoldData(
            datasets=self.datasets,
            flights=FLIGHTS,
            runs=[{"run_id": "20261116T210000Z", "status": "succeeded"}],
            rows_by_resource={FLIGHTS_ID: [{"_id": 1, "CHOPER": "LY"}, {"_id": 2, "CHOPER": "W6"}]},
        )

    def dataset_history(self, dataset_id: str) -> list[dict[str, Any]]:
        return [{"kind": "dataset", "id": dataset_id}]

    def flight_history(self, flight_key: str) -> list[dict[str, Any]]:
        return [{"status_en": "LANDED"}] if flight_key.startswith("W6") else []


@pytest.fixture
def source() -> FakeSource:
    return FakeSource()


@pytest.fixture
def client(source: FakeSource) -> TestClient:
    return TestClient(create_app(source, check_every_s=0))


def test_health_is_not_cached(client: TestClient) -> None:
    r = client.get("/healthz")
    assert r.json() == {"status": "ok"}
    assert r.headers["cache-control"] == "no-store"


def test_list_sorts_by_title_and_sets_cache_headers(client: TestClient) -> None:
    r = client.get("/api/datasets")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 2
    assert [d["name"] for d in body["items"]] == ["flydata", "shelters"]
    assert "max-age=300" in r.headers["cache-control"]
    assert r.headers["x-content-type-options"] == "nosniff"


def test_search_ignores_niqqud_and_matches_columns(client: TestClient) -> None:
    assert [d["name"] for d in client.get("/api/datasets", params={"q": "מקלטים"}).json()["items"]] == [
        "shelters"
    ]
    assert [d["name"] for d in client.get("/api/datasets", params={"q": "choper"}).json()["items"]] == [
        "flydata",
        "shelters",
    ]


def test_filters_sort_and_paging(client: TestClient) -> None:
    def names(**params: Any) -> list[str]:
        return [d["name"] for d in client.get("/api/datasets", params=params).json()["items"]]

    assert names(org="br7") == ["shelters"]
    assert names(tag="תעופה") == ["flydata"]
    assert names(format="xlsx") == ["shelters"]
    assert names(sort="modified") == ["flydata", "shelters"]
    assert names(page=2, size=1) == ["shelters"]
    assert client.get("/api/datasets", params={"sort": "bogus"}).status_code == 422


def test_dataset_detail_history_and_404(client: TestClient) -> None:
    assert client.get("/api/datasets/flydata").json()["title"] == "מאגר טיסות"
    assert client.get("/api/datasets/flydata/history").json()["items"][0]["id"] == "id-flydata"
    assert client.get("/api/datasets/nope").status_code == 404
    assert client.get("/api/datasets/nope/history").status_code == 404


def test_rows_with_columns_and_search(client: TestClient) -> None:
    body = client.get(f"/api/resources/{FLIGHTS_ID}/rows").json()
    assert body["total"] == 2
    assert body["columns"][0]["name"] == "CHOPER"
    assert client.get(f"/api/resources/{FLIGHTS_ID}/rows", params={"q": "w6"}).json()["total"] == 1
    assert client.get("/api/resources/missing/rows").status_code == 404


def test_facets_and_suggest(client: TestClient) -> None:
    facets = client.get("/api/facets").json()
    assert {o["value"] for o in facets["organizations"]} == {"iaa", "br7"}
    assert {f["value"] for f in facets["formats"]} == {"CSV", "XLSX"}
    assert client.get("/api/suggest", params={"q": "ט"}).json()["items"] == []  # needs 2 characters
    hits = client.get("/api/suggest", params={"q": "טיסות"}).json()["items"]
    assert hits == [{"name": "flydata", "title": "מאגר טיסות", "organization": "רשות שדות התעופה"}]


def test_flights_filters_and_history(client: TestClient) -> None:
    body = client.get("/api/flights").json()
    assert [f["flight_number"] for f in body["items"]] == ["002", "001"]  # by scheduled time
    assert {s["value"] for s in body["statuses"]} == {"ON TIME", "LANDED"}
    assert client.get("/api/flights", params={"direction": "arrival"}).json()["total"] == 1
    assert client.get("/api/flights", params={"status": "landed"}).json()["total"] == 1
    assert client.get("/api/flights", params={"q": "ly001"}).json()["total"] == 1
    assert client.get("/api/flights", params={"q": "רומא"}).json()["total"] == 1
    assert client.get("/api/flights", params={"direction": "sideways"}).status_code == 422
    assert client.get("/api/flights/W6-002-arrival-x/history").json()["items"][0]["status_en"] == "LANDED"
    assert client.get("/api/flights/none/history").status_code == 404


def test_status(client: TestClient) -> None:
    body = client.get("/api/status").json()
    assert body["last_run"]["run_id"] == "20261116T210000Z"
    assert body["datasets"] == 2 and body["flights"] == 2
    assert client.get("/api/status").headers["cache-control"] == "public, max-age=60"


def test_reloads_only_when_marker_changes(source: FakeSource) -> None:
    now = {"t": 1000.0}
    cat = Catalog(source, check_every_s=60, clock=lambda: now["t"])
    cat.snapshot()
    assert source.loads == 1
    now["t"] += 120
    cat.snapshot()
    assert source.loads == 1  # marker unchanged
    source.current_marker = "2"
    now["t"] += 30
    cat.snapshot()
    assert source.loads == 1  # changed, but checked less than a minute ago
    now["t"] += 60
    source.datasets = DATASETS[:1]
    assert len(cat.snapshot().data.datasets) == 1
    assert source.loads == 2


def test_normalize_and_plain() -> None:
    assert normalize("  מִקְלָט  Café ") == "מקלט cafe"
    assert normalize(None) == ""

    from datetime import date, datetime

    assert _plain({"a": [datetime(2026, 11, 16)], "b": 1, "c": date(2026, 11, 16)}) == {
        "a": ["2026-11-16T00:00:00Z"],
        "b": 1,
        "c": "2026-11-16",
    }
