#!/usr/bin/env bash
# Builds the one deployable package for App Service: API code + its Python dependencies + the built website.
# CI builds it once per commit; the same zip is deployed to dev, staging and prod.
#
#   scripts/package_app.sh [output.zip]      (default: dist/app.zip)
#
# Layout inside the zip (matches the web app's PYTHONPATH / STATIC_DIR settings):
#   src/catalog/...   the API
#   vendor/...        its dependencies, for Linux x86-64, Python 3.12
#   site/...          the website (Vite build)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/app.zip}"
# The zip is written from inside a temporary directory, so the output path must be absolute.
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "--> website"
(cd "$ROOT/web" && npm ci --no-audit --no-fund && npm run build)
cp -R "$ROOT/web/dist" "$BUILD/site"

echo "--> API dependencies (Linux x86-64, CPython 3.12 wheels only)"
(cd "$ROOT/backend" && uv export --frozen --no-dev --no-emit-project --no-hashes -o "$BUILD/requirements.txt" -q)
python3 -m pip install --quiet --target "$BUILD/vendor" -r "$BUILD/requirements.txt" \
  --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 \
  --implementation cp --python-version 3.12 --only-binary=:all:

echo "--> API code"
mkdir -p "$BUILD/src"
cp -R "$ROOT/backend/src/catalog" "$BUILD/src/catalog"
find "$BUILD" -name '__pycache__' -type d -prune -exec rm -rf {} +

echo "--> zip"
rm -f "$OUT"
(cd "$BUILD" && zip -qr "$OUT" src vendor site)
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
