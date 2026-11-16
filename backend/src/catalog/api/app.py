"""FastAPI app: the public, read-only catalog API (served under /api by the load balancer)."""

from __future__ import annotations

import os
from typing import Annotated, Any

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.middleware.gzip import GZipMiddleware

from catalog.api.catalog import Catalog, page
from catalog.api.source import BigQueryGold, GoldSource

CATALOG_CACHE = "public, max-age=300, stale-while-revalidate=60"
STATUS_CACHE = "public, max-age=60"
HISTORY_CACHE = "public, max-age=600"

Page = Annotated[int, Query(ge=1, le=10000)]
Size = Annotated[int, Query(ge=1, le=200)]
Text = Annotated[str, Query(max_length=200)]


def _default_source() -> GoldSource:
    return BigQueryGold(
        project=os.environ["GCP_PROJECT"],
        dataset=os.environ["GOLD_DATASET"],
        location=os.environ.get("BQ_LOCATION", "me-west1"),
        marker_uri=os.environ["READY_MARKER_URI"],
    )


def create_app(source: GoldSource | None = None, *, check_every_s: float = 60.0) -> FastAPI:
    app = FastAPI(
        title="Agamim open-data catalog API",
        version="1.0.0",
        docs_url="/api/docs",
        openapi_url="/api/openapi.json",
        redoc_url=None,
    )
    app.add_middleware(GZipMiddleware, minimum_size=1024)
    holder: dict[str, Catalog] = {}

    def catalog() -> Catalog:
        if "c" not in holder:
            holder["c"] = Catalog(source or _default_source(), check_every_s=check_every_s)
        return holder["c"]

    @app.middleware("http")
    async def security_headers(request: Any, call_next: Any) -> Any:
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        return response

    @app.get("/healthz", include_in_schema=False)
    def healthz(response: Response) -> dict[str, str]:
        response.headers["Cache-Control"] = "no-store"
        return {"status": "ok"}

    @app.get("/api/status")
    def status(response: Response) -> dict[str, Any]:
        response.headers["Cache-Control"] = STATUS_CACHE
        return catalog().status()

    @app.get("/api/datasets")
    def datasets(
        response: Response,
        q: Text = "",
        org: Text = "",
        tag: Text = "",
        format: Text = "",
        sort: Annotated[str, Query(pattern="^(title|modified)$")] = "title",
        page_no: Annotated[int, Query(alias="page", ge=1, le=10000)] = 1,
        size: Size = 20,
    ) -> dict[str, Any]:
        response.headers["Cache-Control"] = CATALOG_CACHE
        items = catalog().search(q=q, org=org, tag=tag, fmt=format, sort=sort)
        return page(items, page_no, size)

    @app.get("/api/datasets/{name}")
    def dataset(name: str, response: Response) -> dict[str, Any]:
        found = catalog().dataset(name)
        if found is None:
            raise HTTPException(status_code=404, detail="Dataset not found")
        response.headers["Cache-Control"] = CATALOG_CACHE
        return found

    @app.get("/api/datasets/{name}/history")
    def dataset_history(name: str, response: Response) -> dict[str, Any]:
        found = catalog().dataset(name)
        if found is None:
            raise HTTPException(status_code=404, detail="Dataset not found")
        response.headers["Cache-Control"] = HISTORY_CACHE
        return {"items": catalog().dataset_history(found["dataset_id"])}

    @app.get("/api/resources/{resource_id}/rows")
    def resource_rows(
        resource_id: str, response: Response, q: Text = "", page_no: Page = 1, size: Size = 50
    ) -> dict[str, Any]:
        c = catalog()
        found = c.resource(resource_id)
        if found is None:
            raise HTTPException(status_code=404, detail="Table not found")
        _, resource = found
        response.headers["Cache-Control"] = CATALOG_CACHE
        result = page(c.rows(resource_id, q=q), page_no, size)
        result["columns"] = resource.get("columns") or []
        return result

    @app.get("/api/facets")
    def facets(response: Response) -> dict[str, Any]:
        response.headers["Cache-Control"] = CATALOG_CACHE
        return catalog().facets()

    @app.get("/api/suggest")
    def suggest(response: Response, q: Text = "") -> dict[str, Any]:
        response.headers["Cache-Control"] = CATALOG_CACHE
        return {"items": catalog().suggest(q)}

    @app.get("/api/flights")
    def flights(
        response: Response,
        q: Text = "",
        direction: Annotated[str, Query(pattern="^(|arrival|departure)$")] = "",
        status: Text = "",
        page_no: Annotated[int, Query(alias="page", ge=1, le=10000)] = 1,
        size: Size = 50,
    ) -> dict[str, Any]:
        response.headers["Cache-Control"] = CATALOG_CACHE
        c = catalog()
        result = page(c.flights(q=q, direction=direction, status=status), page_no, size)
        result["statuses"] = c.flight_statuses()
        return result

    @app.get("/api/flights/{flight_key}/history")
    def flight_history(flight_key: str, response: Response) -> dict[str, Any]:
        response.headers["Cache-Control"] = HISTORY_CACHE
        items = catalog().flight_history(flight_key)
        if not items:
            raise HTTPException(status_code=404, detail="Flight not found")
        return {"items": items}

    return app


app = create_app()
