#!/usr/bin/env python3
"""Deploy the Data Factory objects in this folder to one environment's factory.

Same files for every environment; only these placeholders differ:
    ${LAKE_DFS_URL}  e.g. https://agamimlakedevdc3eee23.dfs.core.windows.net/
    ${SQL_SERVER}    e.g. sql-agamim-dev-dc3eee23.database.windows.net

Order: stop our triggers -> linked services -> datasets -> pipelines -> triggers -> start triggers (only with
--start-triggers, i.e. prod). Objects that are not in this folder are never touched. Uses the Azure CLI's
sign-in (az login locally, azure/login with OIDC in GitHub Actions).

    python adf/deploy.py --resource-group rg-agamim-catalog-dev-ilc --factory adf-agamim-dev-dc3eee23 \
        --lake-dfs-url https://agamimlakedevdc3eee23.dfs.core.windows.net/ \
        --sql-server sql-agamim-dev-dc3eee23.database.windows.net [--start-triggers] [--run]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
API = "2018-06-01"
KINDS = [("linkedService", "linkedservices"), ("dataset", "datasets"), ("pipeline", "pipelines"), ("trigger", "triggers")]


def az(*args: str) -> str:
    result = subprocess.run(["az", *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"az {' '.join(args[:3])} ... failed:\n{result.stderr.strip()}")
    return result.stdout


def rest(method: str, url: str, body: dict | None = None) -> dict:
    args = ["rest", "--method", method, "--url", url]
    if body is not None:
        args += ["--body", json.dumps(body, ensure_ascii=False), "--headers", "Content-Type=application/json"]
    out = az(*args)
    return json.loads(out) if out.strip() else {}


def load(kind: str, values: dict[str, str]) -> list[dict]:
    objects = []
    for path in sorted((ROOT / kind).glob("*.json")):
        text = path.read_text(encoding="utf-8")
        for key, value in values.items():
            text = text.replace("${" + key + "}", value)
        if "${" in text and "@{" not in text.split("${")[1][:2]:
            leftover = text[text.index("${") : text.index("${") + 40]
            raise SystemExit(f"{path.name}: unreplaced placeholder near {leftover!r}")
        objects.append(json.loads(text))
    return objects


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--resource-group", required=True)
    p.add_argument("--factory", required=True)
    p.add_argument("--lake-dfs-url", required=True)
    p.add_argument("--sql-server", required=True)
    p.add_argument("--start-triggers", action="store_true", help="start schedule triggers (prod only)")
    p.add_argument("--run", metavar="PIPELINE", help="after deploying, run this pipeline and wait for it")
    a = p.parse_args()

    sub = az("account", "show", "--query", "id", "-o", "tsv").strip()
    base = (f"https://management.azure.com/subscriptions/{sub}/resourceGroups/{a.resource_group}"
            f"/providers/Microsoft.DataFactory/factories/{a.factory}")
    values = {"LAKE_DFS_URL": a.lake_dfs_url, "SQL_SERVER": a.sql_server}
    objects = {kind: load(kind, values) for kind, _ in KINDS}

    for trigger in objects["trigger"]:
        existing = rest("GET", f"{base}/triggers?api-version={API}").get("value", [])
        if any(t["name"] == trigger["name"] and t["properties"].get("runtimeState") == "Started" for t in existing):
            print(f"stopping trigger {trigger['name']}")
            rest("POST", f"{base}/triggers/{trigger['name']}/stop?api-version={API}")

    for kind, segment in KINDS:
        for obj in objects[kind]:
            print(f"deploying {kind} {obj['name']}")
            rest("PUT", f"{base}/{segment}/{obj['name']}?api-version={API}", {"properties": obj["properties"]})

    if a.start_triggers:
        for trigger in objects["trigger"]:
            print(f"starting trigger {trigger['name']}")
            rest("POST", f"{base}/triggers/{trigger['name']}/start?api-version={API}")

    if a.run:
        run_id = rest("POST", f"{base}/pipelines/{a.run}/createRun?api-version={API}", {})["runId"]
        print(f"started {a.run}, run {run_id}")
        deadline = time.time() + 30 * 60
        while time.time() < deadline:
            run = rest("GET", f"{base}/pipelineruns/{run_id}?api-version={API}")
            status = run.get("status")
            if status in {"Succeeded", "Failed", "Cancelled"}:
                print(f"{a.run}: {status} in {run.get('durationInMs', 0) / 1000:.0f}s {run.get('message', '')}".rstrip())
                sys.exit(0 if status == "Succeeded" else 1)
            time.sleep(15)
        raise SystemExit(f"{a.run} did not finish within 30 minutes")


if __name__ == "__main__":
    main()
