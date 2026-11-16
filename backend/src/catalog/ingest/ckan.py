"""Small CKAN Action API client with retries and a polite request rate."""

from __future__ import annotations

import time
from collections.abc import Iterator
from typing import Any

import httpx
from tenacity import (
    retry,
    retry_if_exception,
    stop_after_attempt,
    wait_exponential_jitter,
)

USER_AGENT = "Mozilla/5.0 (compatible; open-data-catalog-ingest/0.1)"
PAGE_SIZE = 1000  # CKAN's maximum rows for package_search on data.gov.il
SAMPLE_ROWS = 20

JSONDict = dict[str, Any]


class CkanError(RuntimeError):
    """CKAN answered, but reported a failure (success=false)."""


def _is_retryable(exc: BaseException) -> bool:
    if isinstance(exc, httpx.TransportError):
        return True
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in {429, 500, 502, 503, 504}
    return False


class CkanClient:
    def __init__(
        self,
        base_url: str,
        *,
        min_interval_s: float = 0.2,
        timeout_s: float = 60.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._http = httpx.Client(
            base_url=base_url.rstrip("/") + "/api/3/action/",
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            timeout=timeout_s,
            transport=transport,
            follow_redirects=True,
        )
        self._min_interval_s = min_interval_s
        self._last_call = 0.0

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> CkanClient:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _throttle(self) -> None:
        wait = self._min_interval_s - (time.monotonic() - self._last_call)
        if wait > 0:
            time.sleep(wait)
        self._last_call = time.monotonic()

    @retry(
        retry=retry_if_exception(_is_retryable),
        wait=wait_exponential_jitter(initial=1, max=30),
        stop=stop_after_attempt(5),
        reraise=True,
    )
    def action(self, name: str, params: dict[str, str | int]) -> Any:
        self._throttle()
        response = self._http.get(name, params=params)
        response.raise_for_status()
        body = response.json()
        if not isinstance(body, dict) or not body.get("success"):
            raise CkanError(f"{name} failed: {body.get('error') if isinstance(body, dict) else body!r}")
        return body["result"]

    def iter_packages(self) -> Iterator[JSONDict]:
        """Yields every public dataset (package), with its organization, tags and resources."""
        start = 0
        while True:
            result = self.action(
                "package_search",
                {"rows": PAGE_SIZE, "start": start, "sort": "id asc", "include_private": "false"},
            )
            page: list[JSONDict] = result["results"]
            yield from page
            start += len(page)
            if not page or start >= int(result["count"]):
                return

    def package_show(self, name_or_id: str) -> JSONDict:
        """One dataset by name or id, in the same shape package_search returns."""
        result: JSONDict = self.action("package_show", {"id": name_or_id})
        return result

    def datastore_rows(self, resource_id: str, *, page_size: int = 10000, max_rows: int = 200000) -> JSONDict:
        """Every row of a datastore table (up to max_rows), with its columns and total."""
        offset = 0
        fields: list[JSONDict] = []
        records: list[JSONDict] = []
        total = 0
        while True:
            result = self.action(
                "datastore_search",
                {"resource_id": resource_id, "limit": page_size, "offset": offset, "include_total": "true"},
            )
            if offset == 0:
                fields = result.get("fields", [])
                total = int(result.get("total") or 0)
            page: list[JSONDict] = result.get("records", [])
            records.extend(page)
            offset += len(page)
            if not page or offset >= total or offset >= max_rows:
                break
        return {"resource_id": resource_id, "fields": fields, "total": total, "records": records[:max_rows]}

    def datastore_preview(self, resource_id: str) -> JSONDict:
        """Columns, total row count and the first rows of a datastore resource."""
        result = self.action(
            "datastore_search",
            {"resource_id": resource_id, "limit": SAMPLE_ROWS, "include_total": "true"},
        )
        return {
            "resource_id": resource_id,
            "fields": result.get("fields", []),
            "total": result.get("total"),
            "total_was_estimated": result.get("total_was_estimated", False),
            "records": result.get("records", []),
        }
