"""Build the single authoritative inventory used by the website.

Everything the public pages state about the estate's size, recovery state or
backup coverage is derived from this file, so a stale hand-written number
cannot survive a rebuild.

Counting rules (kept deliberately narrow and printed in the JSON):
  * tables  = user tables, excluding the six dbo.sysdiagrams support tables
  * views   = user views (diagram support creates none)
  * procedures = user procedures, excluding the seven sp_*diagram helpers
  * rows    = SUM(sys.partitions.rows) for heaps and clustered indexes
  * foreign keys = every FK in the database
  * size    = SUM(sys.database_files.size) in MB (data + log)

The three engines are reported separately. Their object counts are never added
together: nine SQL Server databases, one Oracle schema in FREEPDB1, and one
MySQL schema are different scopes.

Run from the repository root:  python tools/audit/build_inventory.py [--refresh]

The published snapshot is pinned: without --refresh an existing
site/data/inventory.json is reused, so routine rebuilds cannot move the
headline row count just because an audit table gained rows.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import inventory_scope  # noqa: E402  (shared lab-exclusion rule)

ROOT = Path(__file__).resolve().parents[2]
SQLCMD = os.environ.get(
    "AFS_SQLCMD",
    r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE",
)
MYSQL = os.environ.get("AFS_MYSQL", r"C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe")
SECRETS = ROOT / ".secrets"
OUT_JSON = ROOT / "site" / "data" / "inventory.json"
OUT_MD = ROOT / "docs" / "audit" / "AUTHORITATIVE_INVENTORY.md"

SERVER_SQL = """
SET NOCOUNT ON;
SELECT
    SERVERPROPERTY('ServerName') AS instance,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)) AS version,
    CAST(SERVERPROPERTY('Edition') AS varchar(100)) AS edition;
"""
INVENTORY_SQL = ROOT / "tools" / "audit" / "inventory_query.sql"


def run(cmd: list[str], env: dict | None = None, timeout: int = 120,
        stdin: str | None = None) -> str:
    proc = subprocess.run(
        cmd, input=stdin, capture_output=True, text=True, encoding="utf-8",
        errors="replace", env=env, timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "command failed")
    return proc.stdout


def sqlcmd_rows(query: str | None = None, script: Path | None = None) -> list[list[str]]:
    args = [SQLCMD, "-S", "localhost", "-E", "-C", "-h-1", "-W", "-s", "|"]
    if script is not None:
        args += ["-i", str(script)]
    else:
        args += ["-Q", query or "SET NOCOUNT ON;"]
    out = run(args)
    rows = []
    for line in out.replace("\r", "").splitlines():
        line = line.strip()
        if not line or set(line) <= {"-", "|"}:
            continue
        rows.append([cell.strip() for cell in line.split("|")])
    return rows


def num(value: str) -> int:
    return 0 if value in ("", "NULL", None) else int(value)


def secret(name: str) -> str:
    path = SECRETS / name
    if not path.exists():
        raise FileNotFoundError(f"missing secret file: {path}")
    return path.read_text(encoding="utf-8-sig").strip()


def mysql_inventory() -> dict:
    env = dict(os.environ, MYSQL_PWD=secret("mysql_root_password.txt"))
    query = (
        "SELECT @@version, @@hostname;"
        "SELECT table_schema, COUNT(*), COALESCE(SUM(table_rows),0)"
        " FROM information_schema.tables WHERE table_schema LIKE 'afs_lab%'"
        " GROUP BY table_schema ORDER BY table_schema;"
        "SELECT COUNT(*), COALESCE(SUM(balance),0) FROM afs_lab.account;"
        "SELECT COUNT(*) FROM afs_lab.ledger_entry;"
    )
    out = run([MYSQL, "-u", "root", "-h", "127.0.0.1", "-N", "-e", query], env=env)
    lines = [l for l in out.replace("\r", "").splitlines() if l.strip()]
    version, host = lines[0].split("\t")[:2]
    schemas = []
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].startswith("afs_lab"):
            schemas.append({"schema": parts[0], "tables": int(parts[1]),
                            "approx_rows": int(parts[2])})
    accounts, balance = lines[-2].split("\t")[:2]
    ledger = lines[-1].strip()
    return {
        "engine": "MySQL",
        "version": version,
        "host": host,
        "schemas": schemas,
        "lab": {
            "schema": "afs_lab",
            "accounts": int(accounts),
            "ledger_entries": int(ledger),
            "balance_total": float(balance),
        },
        "scope": "one schema (afs_lab) plus its scratch restore copy",
    }


def oracle_inventory() -> dict:
    env = dict(os.environ, MSYS2_ARG_CONV_EXCL="*")
    pw = secret("oracle_sys_password.txt")
    sql = """SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300
SELECT banner_full FROM v$version WHERE ROWNUM=1;
SELECT name || '|' || open_mode || '|' || log_mode FROM v$database;
SELECT name || '|' || open_mode FROM v$pdbs WHERE name='FREEPDB1';
ALTER SESSION SET CONTAINER=FREEPDB1;
SELECT (SELECT COUNT(*) FROM AFS_LAB.ACCOUNT) || '|' ||
       (SELECT COUNT(*) FROM AFS_LAB.LEDGER_ENTRY) || '|' ||
       (SELECT SUM(balance) FROM AFS_LAB.ACCOUNT) || '|' ||
       (SELECT COUNT(*) FROM dba_tables WHERE owner='AFS_LAB')
FROM dual;
EXIT
"""
    stdin = f"CONNECT sys/{pw}@FREE as sysdba\n{sql}\nEXIT\n"
    out = run(["sqlplus", "-s", "/nolog"], env=env, stdin=stdin)
    lines = [l.strip() for l in out.replace("\r", "").splitlines() if l.strip()]
    version = next((l for l in lines if l.startswith("Oracle AI Database")), "Oracle 26ai")
    db_line = next(l for l in lines if l.startswith("FREE|"))
    pdb_line = next(l for l in lines if l.startswith("FREEPDB1|"))
    counts = next(l for l in lines if re.match(r"^\d+\|\d+\|", l)).split("|")
    return {
        "engine": "Oracle",
        "version": version,
        "instance": db_line.split("|")[0],
        "pdb": pdb_line.split("|")[0],
        "open_mode": pdb_line.split("|")[1],
        "log_mode": db_line.split("|")[2],
        "tables": int(counts[3]),
        "lab": {
            "schema": "AFS_LAB",
            "accounts": int(counts[0]),
            "ledger_entries": int(counts[1]),
        },
        "scope": "one pluggable database (FREEPDB1), one lab schema (AFS_LAB)",
    }


def main() -> int:
    refresh = "--refresh" in sys.argv[1:]
    if OUT_JSON.exists() and not refresh:
        print(json.dumps({
            "pinned": True,
            "path": str(OUT_JSON),
            "note": "inventory snapshot reused; pass --refresh to re-read the catalog",
        }, indent=2))
        return 0
    generated = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    server = sqlcmd_rows(SERVER_SQL)[0]
    instance = {"instance": server[0], "version": server[1], "edition": server[2]}
    import tempfile

    expanded = inventory_scope.expand_sql(INVENTORY_SQL.read_text(encoding="utf-8"), quote="''")
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False, encoding="utf-8") as handle:
        handle.write(expanded)
        temp_sql = Path(handle.name)
    try:
        rows = sqlcmd_rows(script=temp_sql)
    finally:
        temp_sql.unlink(missing_ok=True)

    databases = []
    for r in rows:
        if len(r) < 13:
            continue
        databases.append({
            "name": r[0],
            "state": r[1],
            "recovery_model": r[2],
            "tables": num(r[3]),
            "views": num(r[4]),
            "procedures": num(r[5]),
            "foreign_keys": num(r[6]),
            "rows": num(r[7]),
            "size_mb": 0.0 if r[8] in ("", "NULL") else float(r[8]),
            "last_full": None if r[9] in ("", "NULL") else r[9],
            "last_log": None if r[10] in ("", "NULL") else r[10],
            "full_sets": num(r[11]),
            "log_sets": num(r[12]),
        })

    totals = {
        "databases": len(databases),
        "tables": sum(d["tables"] for d in databases),
        "views": sum(d["views"] for d in databases),
        "procedures": sum(d["procedures"] for d in databases),
        "foreign_keys": sum(d["foreign_keys"] for d in databases),
        "rows": sum(d["rows"] for d in databases),
        "size_mb": round(sum(d["size_mb"] for d in databases), 1),
        "full_sets": sum(d["full_sets"] for d in databases),
        "log_sets": sum(d["log_sets"] for d in databases),
    }

    inventory = {
        "generated_at_utc": generated,
        "counting_rules": {
            "tables": "user tables; excludes the dbo.sysdiagrams support table present in six databases",
            "views": "user views (is_ms_shipped = 0)",
            "procedures": "user procedures; excludes the seven sp_*diagram helpers per database",
            "rows": "SUM(sys.partitions.rows) over heaps and clustered indexes of user tables",
            "foreign_keys": "every foreign key in the database",
            "size_mb": "SUM(sys.database_files.size) for data and log files",
            "backup_sets": "rows in msdb.dbo.backupset for databases whose name starts with AFS_",
        },
        "sqlserver": {**instance, "databases": databases, "totals": totals},
        "oracle": oracle_inventory(),
        "mysql": mysql_inventory(),
        "engine_scope_note": (
            "SQL Server counts nine databases. Oracle counts one schema inside one pluggable "
            "database. MySQL counts one schema plus its restore copy. The three are reported "
            "separately and are never summed into one database or table count."
        ),
    }

    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")

    md = [
        "# Authoritative inventory",
        "",
        f"Generated from the running instances at **{generated}**.",
        "",
        "## SQL Server",
        "",
        f"`{instance['instance']}` — SQL Server {instance['version']}, {instance['edition']}.",
        "",
        "| Database | Tables | Views | Procs | FKs | Rows | MB | Recovery | Last full | Full sets | Log sets |",
        "|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|",
    ]
    for d in databases:
        md.append(
            f"| {d['name']} | {d['tables']} | {d['views']} | {d['procedures']} | "
            f"{d['foreign_keys']} | {d['rows']:,} | {d['size_mb']:.1f} | {d['recovery_model']} | "
            f"{d['last_full'] or '—'} | {d['full_sets']} | {d['log_sets']} |"
        )
    md += [
        "",
        f"**Totals:** {totals['databases']} databases, {totals['tables']} tables, "
        f"{totals['views']} views, {totals['procedures']} procedures, "
        f"{totals['foreign_keys']} foreign keys, {totals['rows']:,} rows, "
        f"{totals['size_mb']:.1f} MB allocated.",
        "",
        "Counting rules: tables exclude the `dbo.sysdiagrams` support table in six databases; "
        "procedures exclude the seven `sp_*diagram` helpers in each database; rows are the "
        "partition-row sum over user tables.",
        "",
        f"## Oracle — {inventory['oracle']['version']}",
        "",
        f"PDB `{inventory['oracle']['pdb']}`, {inventory['oracle']['open_mode']}, "
        f"{inventory['oracle']['log_mode']}. Schema `AFS_LAB`: "
        f"{inventory['oracle']['lab']['accounts']:,} accounts, "
        f"{inventory['oracle']['lab']['ledger_entries']:,} ledger entries.",
        "",
        f"## MySQL — {inventory['mysql']['version']}",
        "",
        f"Schema `afs_lab`: {inventory['mysql']['lab']['accounts']:,} accounts, "
        f"{inventory['mysql']['lab']['ledger_entries']:,} ledger entries. "
        "A second schema, `afs_lab_restore`, holds the dump-restore proof.",
        "",
        "The three engines are separate scopes; their counts are not summed.",
        "",
    ]
    OUT_MD.parent.mkdir(parents=True, exist_ok=True)
    OUT_MD.write_text("\n".join(md), encoding="utf-8")

    print(json.dumps({
        "generated_at_utc": generated,
        "sqlserver": totals,
        "oracle": inventory["oracle"]["lab"],
        "mysql": inventory["mysql"]["lab"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
