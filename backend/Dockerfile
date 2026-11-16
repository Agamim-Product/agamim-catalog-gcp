# One image, two entrypoints:
#   catalog-ingest-<env>  (Cloud Run Job):     command ["catalog-ingest"]
#   catalog-api-<env>     (Cloud Run service): default command, serves on $PORT
FROM python:3.12.8-slim-bookworm AS build
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev

FROM python:3.12.8-slim-bookworm
RUN useradd --system --uid 10001 app
WORKDIR /app
COPY --from=build --chown=app:app /app /app
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PORT=8080
USER app
EXPOSE 8080
CMD ["sh", "-c", "exec uvicorn catalog.api.app:app --host 0.0.0.0 --port ${PORT} --proxy-headers --forwarded-allow-ips='*'"]
