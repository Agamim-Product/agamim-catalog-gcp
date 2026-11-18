#!/usr/bin/env python3
"""Checks the Data Factory files before anything is deployed (runs on every pull request).

- every file is valid JSON whose "name" matches its file name
- every linked service / dataset / pipeline reference points to an object in this folder
- only the placeholders deploy.py knows are used (${LAKE_DFS_URL}, ${SQL_SERVER})
- triggers are committed stopped (deploy.py starts them in prod only)
- REST paging is bounded, so a broken stop condition can never loop forever
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
KINDS = {"linkedService": "LinkedServiceReference", "dataset": "DatasetReference", "pipeline": "PipelineReference"}
ALLOWED_PLACEHOLDERS = {"LAKE_DFS_URL", "SQL_SERVER"}
PLACEHOLDER = re.compile(r"\$\{([A-Z_]+)\}")


def refs(node: Any) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    if isinstance(node, dict):
        if "referenceName" in node and "type" in node:
            found.append((node["type"], node["referenceName"]))
        for value in node.values():
            found += refs(value)
    elif isinstance(node, list):
        for value in node:
            found += refs(value)
    return found


LEGEND = ROOT.parent / "web" / "src" / "data" / "flydata-columns.json"


def check_column_dictionary(errors: list[str]) -> None:
    """The Copy step's column mapping and the catalog's column dictionary must describe the same columns."""
    legend = json.loads(LEGEND.read_text(encoding="utf-8"))
    pipeline = json.loads((ROOT / "pipeline" / "pl_ingest_flydata.json").read_text(encoding="utf-8"))
    copy = next(a for a in pipeline["properties"]["activities"] if a["name"] == "CopyRowsToSilver")
    mapped = {m["source"]["path"].strip("[]'"): m["sink"]["name"] for m in copy["typeProperties"]["translator"]["mappings"]
              if m["source"].get("path", "").startswith("['CH")}  # source columns; added columns are not in the dictionary's CH list
    documented = {r["source"]: r["column"] for r in legend if r["column"] and r["source"].startswith("CH")}
    for source, column in mapped.items():
        if documented.get(source) != column:
            errors.append(f"column dictionary: {source} is mapped to {column!r} but documented as {documented.get(source)!r}")
    for source in documented.keys() - mapped.keys():
        errors.append(f"column dictionary: {source} is documented as copied but is not in the mapping")
    # Azure allows at most 5 user properties per activity, so the explanations live in the activity description.
    missing = [r["source"] for r in legend if r["source"].startswith("CH") and r["source"] not in copy.get("description", "")]
    if missing:
        errors.append(f"CopyRowsToSilver description does not explain: {', '.join(missing)}")
    if len(copy.get("userProperties", [])) > 5:
        errors.append("CopyRowsToSilver has more than 5 user properties (Azure rejects the run)")


def main() -> int:
    errors: list[str] = []
    names: dict[str, set[str]] = {}
    docs: dict[Path, dict[str, Any]] = {}
    for kind in [*KINDS, "trigger"]:
        names[kind] = set()
        for path in sorted((ROOT / kind).glob("*.json")):
            text = path.read_text(encoding="utf-8")
            for placeholder in PLACEHOLDER.findall(text):
                if placeholder not in ALLOWED_PLACEHOLDERS:
                    errors.append(f"{path.name}: unknown placeholder ${{{placeholder}}}")
            try:
                doc = json.loads(text)
            except json.JSONDecodeError as exc:
                errors.append(f"{path.name}: invalid JSON ({exc})")
                continue
            if doc.get("name") != path.stem:
                errors.append(f"{path.name}: name {doc.get('name')!r} does not match the file name")
            names[kind].add(doc.get("name", ""))
            docs[path] = doc

    by_type = {ref_type: names[kind] for kind, ref_type in KINDS.items()}
    for path, doc in docs.items():
        for ref_type, ref_name in refs(doc):
            if ref_type in by_type and ref_name not in by_type[ref_type]:
                errors.append(f"{path.name}: {ref_type} {ref_name!r} does not exist")
        if path.parent.name == "trigger" and doc["properties"].get("runtimeState") != "Stopped":
            errors.append(f"{path.name}: commit triggers as Stopped; deploy.py starts them where needed")
        if path.parent.name == "pipeline":
            for activity in doc["properties"].get("activities", []):
                rules = activity.get("typeProperties", {}).get("source", {}).get("paginationRules", {})
                for key, value in rules.items():
                    if isinstance(value, str) and value.startswith("RANGE:") and value.split(":")[2] == "":
                        errors.append(f"{path.name}/{activity['name']}: {key} has no upper bound")

    check_column_dictionary(errors)
    for error in errors:
        print(f"ERROR {error}")
    total = sum(len(v) for v in names.values())
    print(f"{total} Data Factory objects checked, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
