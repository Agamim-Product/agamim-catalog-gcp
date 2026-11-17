#!/usr/bin/env python3
"""Apply SQL migrations (sql/migrations/V###__name.sql) to one environment's `gold` database.

A migration runs when its version is not yet in meta.schema_migration, or when its file changed (checksum
differs). Every migration is written to be safe to run again (CREATE OR ALTER, IF ... IS NULL), so re-running
a changed one is how stored procedures are updated. Uses go-sqlcmd with the Azure CLI's Entra ID sign-in.

    python sql/migrate.py --server sql-agamim-dev-dc3eee23.database.windows.net [--dry-run]
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parent / "migrations"
NAME = re.compile(r"^V(\d{3})__[a-z0-9_]+\.sql$")


def sqlcmd(server: str, *args: str) -> str:
    cmd = ["sqlcmd", "-S", server, "-d", "gold", "--authentication-method", "ActiveDirectoryAzCli", "-b", "-h", "-1", "-W"]
    result = subprocess.run([*cmd, *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"sqlcmd failed:\n{result.stdout}\n{result.stderr}".strip())
    return result.stdout


def applied(server: str) -> dict[str, str]:
    out = sqlcmd(
        server,
        "-Q",
        "SET NOCOUNT ON; IF OBJECT_ID('meta.schema_migration') IS NOT NULL "
        "SELECT CONCAT(version, '|', checksum) FROM meta.schema_migration;",
    )
    rows = [line.split("|", 1) for line in out.splitlines() if "|" in line]
    return {v: c for v, c in rows}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--server", required=True)
    p.add_argument("--dry-run", action="store_true", help="list what would run, change nothing")
    a = p.parse_args()

    files = sorted(f for f in MIGRATIONS.glob("*.sql") if NAME.match(f.name))
    bad = [f.name for f in MIGRATIONS.glob("*.sql") if not NAME.match(f.name)]
    if bad:
        raise SystemExit(f"migration file names must look like V001__name.sql: {bad}")

    done = applied(a.server)
    pending = []
    for f in files:
        version = f.name.split("__", 1)[0]
        checksum = hashlib.sha256(f.read_bytes()).hexdigest()
        if done.get(version) != checksum:
            pending.append((version, checksum, f))

    if not pending:
        print("database is up to date")
        return
    for version, checksum, f in pending:
        print(f"{'would apply' if a.dry_run else 'applying'} {f.name}")
        if a.dry_run:
            continue
        sqlcmd(a.server, "-i", str(f))
        sqlcmd(
            a.server,
            "-Q",
            "MERGE meta.schema_migration AS t USING (SELECT "
            f"'{version}' AS version, '{checksum}' AS checksum) AS s ON t.version = s.version "
            "WHEN MATCHED THEN UPDATE SET checksum = s.checksum, applied_at = SYSUTCDATETIME() "
            "WHEN NOT MATCHED THEN INSERT (version, checksum) VALUES (s.version, s.checksum);",
        )


if __name__ == "__main__":
    main()
