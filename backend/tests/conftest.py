from __future__ import annotations

import copy
from typing import Any

import pytest

BASE = "https://ckan.test"


def make_package(
    pid: str, *, modified: str = "2026-11-01T10:00:00", ds_modified: str = "2026-11-01T09:00:00"
) -> dict[str, Any]:
    return {
        "id": pid,
        "name": f"dataset-{pid}",
        "title": f"מאגר {pid}",
        "notes": "תיאור",
        "metadata_created": "2020-01-01T00:00:00",
        "metadata_modified": modified,
        "license_title": "Other (Open)",
        "author": None,
        "maintainer": None,
        "num_resources": 2,
        "state": "active",
        "organization": {
            "id": "org-1",
            "name": "moh",
            "title": "משרד הבריאות",
            "description": "",
            "image_url": "",
        },
        "tags": [{"name": "בריאות"}],
        "extras": [{"key": "Frequency", "value": "Daily"}],
        "resources": [
            {
                "id": f"{pid}-r1",
                "package_id": pid,
                "name": "קובץ נתונים",
                "format": "CSV",
                "datastore_active": True,
                "last_modified": ds_modified,
                "metadata_modified": ds_modified,
                "size": 100,
                "url": f"https://example.test/{pid}.csv",
            },
            {
                "id": f"{pid}-r2",
                "package_id": pid,
                "name": "מסמך",
                "format": "PDF",
                "datastore_active": False,
                "last_modified": None,
                "metadata_modified": ds_modified,
                "size": 10,
                "url": f"https://example.test/{pid}.pdf",
            },
        ],
    }


def datastore_result(rid: str) -> dict[str, Any]:
    return {
        "success": True,
        "result": {
            "resource_id": rid,
            "fields": [{"id": "_id", "type": "int"}, {"id": "city", "type": "text"}],
            "records": [{"_id": 1, "city": "תל אביב"}],
            "total": 1,
            "total_was_estimated": False,
        },
    }


@pytest.fixture
def packages() -> list[dict[str, Any]]:
    return [make_package("a"), make_package("b"), make_package("c")]


@pytest.fixture
def clone() -> Any:
    return copy.deepcopy
