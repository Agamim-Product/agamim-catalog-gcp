from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
import pytest
import respx

from catalog.ingest import ckan as ckan_module
from catalog.ingest.bronze import LocalStore, open_store, partition_key, to_ndjson
from catalog.ingest.ckan import CkanClient, CkanError
from catalog.ingest.main import STATE_KEY, Settings, run
from tests.conftest import BASE, datastore_result, make_package

NOW = datetime(2026, 11, 16, 20, 30, tzinfo=UTC)


def settings(tmp_path: Path, **kw: Any) -> Settings:
    base = {
        "ckan_base_url": BASE,
        "bronze_uri": f"file://{tmp_path}",
        "run_id": "20261116T203000Z",
        "max_datastore_calls": 100,
        "min_interval_s": 0.0,
    }
    base.update(kw)
    return Settings(**base)


def mock_ckan(router: respx.Router, packages: list[dict[str, Any]], page_size: int = 2) -> None:
    def search(request: httpx.Request) -> httpx.Response:
        start = int(request.url.params["start"])
        page = packages[start : start + page_size]
        return httpx.Response(
            200, json={"success": True, "result": {"count": len(packages), "results": page}}
        )

    by_name = {p["name"]: p for p in packages}

    def show(request: httpx.Request) -> httpx.Response:
        found = by_name.get(request.url.params["id"])
        if found is None:
            return httpx.Response(404, json={"success": False, "error": {"message": "Not found"}})
        return httpx.Response(200, json={"success": True, "result": found})

    router.get(f"{BASE}/api/3/action/package_search").mock(side_effect=search)
    router.get(f"{BASE}/api/3/action/package_show").mock(side_effect=show)
    router.get(f"{BASE}/api/3/action/datastore_search").mock(
        side_effect=lambda r: httpx.Response(200, json=datastore_result(r.url.params["resource_id"]))
    )


def read_lines(tmp_path: Path, entity: str, run_id: str = "20261116T203000Z") -> list[dict[str, Any]]:
    path = tmp_path / partition_key(entity, run_id, NOW)
    text = path.read_text(encoding="utf-8")
    return [json.loads(line) for line in text.splitlines() if line]


@pytest.fixture(autouse=True)
def small_pages(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ckan_module, "PAGE_SIZE", 2)


def test_full_run_writes_packages_datastore_and_run_record(
    tmp_path: Path, packages: list[dict[str, Any]]
) -> None:
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path), LocalStore(tmp_path), client, NOW)

    assert stats.packages == 3
    assert stats.resources == 6
    assert stats.datastore_fetched == 3  # only the datastore_active resources
    pkg_lines = read_lines(tmp_path, "package")
    assert [line["entity_id"] for line in pkg_lines] == ["a", "b", "c"]
    payload = json.loads(pkg_lines[0]["payload"])
    assert payload["title"] == "מאגר a"  # Hebrew kept as-is, unchanged from the source
    ds_lines = read_lines(tmp_path, "datastore")
    assert {line["entity_id"] for line in ds_lines} == {"a-r1", "b-r1", "c-r1"}
    assert json.loads(ds_lines[0]["payload"])["fields"][1]["id"] == "city"
    run_record = json.loads(read_lines(tmp_path, "run")[0]["payload"])
    assert run_record["status"] == "succeeded"
    assert run_record["packages"] == 3
    rows = read_lines(tmp_path, "records")
    assert [line["entity_id"] for line in rows] == ["a-r1:1", "b-r1:1", "c-r1:1"]
    assert json.loads(rows[0]["payload"]) == {"resource_id": "a-r1", "row": {"_id": 1, "city": "תל אביב"}}


def test_selected_datasets_use_package_show(tmp_path: Path, packages: list[dict[str, Any]]) -> None:
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path, datasets=("dataset-b",)), LocalStore(tmp_path), client, NOW)
        assert not router.routes[0].called  # package_search was never used
    assert stats.packages == 1
    assert [line["entity_id"] for line in read_lines(tmp_path, "package")] == ["b"]
    assert json.loads(read_lines(tmp_path, "run")[0]["payload"])["datasets"] == ["dataset-b"]


def test_unknown_dataset_fails_the_run(tmp_path: Path, packages: list[dict[str, Any]]) -> None:
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client, pytest.raises(httpx.HTTPStatusError):
            run(settings(tmp_path, datasets=("missing",)), LocalStore(tmp_path), client, NOW)


def test_preview_mode_writes_no_rows(tmp_path: Path, packages: list[dict[str, Any]]) -> None:
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path, full_rows=False), LocalStore(tmp_path), client, NOW)
    assert stats.rows_fetched == 0
    assert read_lines(tmp_path, "records") == []


def test_datastore_rows_paginates() -> None:
    def page(request: httpx.Request) -> httpx.Response:
        offset = int(request.url.params["offset"])
        records = [{"_id": i} for i in range(offset + 1, min(offset + 2, 3) + 1)]
        body = {"fields": [{"id": "_id", "type": "int"}], "total": 3, "records": records}
        return httpx.Response(200, json={"success": True, "result": body})

    with respx.mock as router:
        route = router.get(f"{BASE}/api/3/action/datastore_search").mock(side_effect=page)
        with CkanClient(BASE, min_interval_s=0) as client:
            table = client.datastore_rows("r", page_size=2)
    assert [r["_id"] for r in table["records"]] == [1, 2, 3]
    assert route.call_count == 2


def test_second_run_skips_unchanged_datastore_resources(
    tmp_path: Path, packages: list[dict[str, Any]]
) -> None:
    store = LocalStore(tmp_path)
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            run(settings(tmp_path), store, client, NOW)
        changed = [make_package("a", ds_modified="2026-11-16T20:00:00"), packages[1], packages[2]]
        router.routes.clear()
        mock_ckan(router, changed)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path, run_id="second"), store, client, NOW)

    assert stats.datastore_candidates == 1
    assert [line["entity_id"] for line in read_lines(tmp_path, "datastore", "second")] == ["a-r1"]


def test_failed_preview_is_counted_and_retried_next_run(
    tmp_path: Path, packages: list[dict[str, Any]], monkeypatch: pytest.MonkeyPatch
) -> None:
    store = LocalStore(tmp_path)
    with respx.mock as router:
        # Registered first, so it wins over the general datastore route.
        router.get(f"{BASE}/api/3/action/datastore_search", params={"resource_id": "b-r1"}).mock(
            return_value=httpx.Response(200, json={"success": False, "error": {"message": "nope"}})
        )
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path), store, client, NOW)

    assert stats.datastore_failed == 1
    assert stats.failed_resource_ids == ["b-r1"]
    state = json.loads((tmp_path / STATE_KEY).read_text())
    assert "b-r1" not in state  # not marked as done, so the next run tries again


def test_cap_leaves_the_rest_pending(tmp_path: Path, packages: list[dict[str, Any]]) -> None:
    with respx.mock as router:
        mock_ckan(router, packages)
        with CkanClient(BASE, min_interval_s=0) as client:
            stats = run(settings(tmp_path, max_datastore_calls=1), LocalStore(tmp_path), client, NOW)
    assert stats.datastore_fetched == 1
    assert stats.datastore_pending == 2


def test_empty_catalog_fails_the_run(tmp_path: Path) -> None:
    with respx.mock as router:
        mock_ckan(router, [])
        with CkanClient(BASE, min_interval_s=0) as client, pytest.raises(RuntimeError):
            run(settings(tmp_path), LocalStore(tmp_path), client, NOW)
    assert not (tmp_path / "ckan").exists()


def test_retries_transient_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("tenacity.nap.time.sleep", lambda _s: None)
    calls = {"n": 0}

    def flaky(_request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        if calls["n"] < 3:
            return httpx.Response(503)
        return httpx.Response(200, json={"success": True, "result": {"ok": 1}})

    with respx.mock as router:
        router.get(f"{BASE}/api/3/action/status_show").mock(side_effect=flaky)
        with CkanClient(BASE, min_interval_s=0) as client:
            assert client.action("status_show", {}) == {"ok": 1}
    assert calls["n"] == 3


def test_does_not_retry_client_errors() -> None:
    with respx.mock as router:
        route = router.get(f"{BASE}/api/3/action/status_show").mock(return_value=httpx.Response(404))
        with CkanClient(BASE, min_interval_s=0) as client, pytest.raises(httpx.HTTPStatusError):
            client.action("status_show", {})
    assert route.call_count == 1


def test_unsuccessful_body_raises() -> None:
    with respx.mock as router:
        router.get(f"{BASE}/api/3/action/x").mock(return_value=httpx.Response(200, json={"success": False}))
        with CkanClient(BASE, min_interval_s=0) as client, pytest.raises(CkanError):
            client.action("x", {})


def test_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("BRONZE_URI", "file:///tmp/x")
    monkeypatch.delenv("RUN_ID", raising=False)
    s = Settings.from_env(NOW)
    assert s.run_id == "20261116T203000Z"
    assert s.ckan_base_url == "https://data.gov.il"


def test_open_store_and_ndjson(tmp_path: Path) -> None:
    store = open_store(f"file://{tmp_path}")
    assert store.read_text("missing") is None
    with pytest.raises(ValueError, match="Unsupported"):
        open_store("s3://bucket")
    body, n = to_ndjson("r", NOW, [])
    assert (body, n) == ("", 0)
