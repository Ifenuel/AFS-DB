"""Regenerate the Explorer's embedded catalog from the live SQL Server catalogs.

The Explorer used to carry a hand-generated snapshot of six databases, which is
how it drifted from the nine-database estate. This script reads tables, columns,
indexes and foreign keys for every AFS database and replaces only the
`window.AFS_DATA` line in site/explorer.html.

Run: python tools/audit/build_explorer.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import inventory_scope  # noqa: E402  (shared lab-exclusion rule)

ROOT = Path(__file__).resolve().parents[2]
EXPLORER = ROOT / "site" / "explorer.html"
SQLCMD = r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"

DOMAIN_MAP = {
    "account": ("account", "Account", "Account headers, status, currency and limits."),
    "ledger": ("ledger", "Ledger", "Double-entry postings behind every balance change."),
    "transfer": ("transfer", "Transfer", "Money movement between accounts and its event trail."),
    "audit": ("audit", "Audit", "Append-only audit events written inside the business transaction."),
    "customer": ("customer", "Customer", "KYC record, addresses and contacts."),
    "reference": ("reference", "Reference", "Controlled lists: country, currency, account type and status."),
    "payment": ("payment", "Payment", "Inbound and outbound payments with method and status."),
    "settlement": ("settlement", "Settlement", "Batch settlement of payments."),
    "fraud": ("fraud", "Fraud", "Rules, alerts and cases."),
    "support": ("service", "Service", "Customer service requests, categories and case notes."),
    "service_request": ("service", "Service", "Service requests opened from a case."),
    "escalation": ("service", "Service", "Escalation path for support cases."),
    "reporting": ("reporting", "Reporting", "Reporting outputs and daily summaries."),
    "staging": ("reporting", "Reporting", "Staging area loaded from the core estate."),
    "warehouse": ("reporting", "Reporting", "Dimensional warehouse: dimensions and fact."),
    "iam": ("identity", "Identity", "Principals, roles, grants, reviews and sessions."),
    "grc": ("compliance", "Compliance", "Obligations, controls, tests, findings and key custody."),
    "retention": ("archive", "Archive", "Retention policy, legal hold and archived records."),
    "telemetry": ("archive", "Archive", "Historian readings and recorded collection gaps."),
    "administration": ("platform", "Platform", "Administrative actions."),
    "operational": ("platform", "Platform", "Backup and job history."),
    "security": ("platform", "Platform", "Security events."),
    "dbo": ("platform", "Platform", "Operational log tables."),
}

TABLE_DOMAIN = {
    "account.Account": "account",
    "account.AccountLedgerEntry": "ledger",
    "account.Transfer": "transfer",
    "account.TransferEvent": "transfer",
}

TABLES_SQL = """
SET NOCOUNT ON;
SELECT s.name, t.name,
 (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id=t.object_id AND p.index_id IN (0,1))
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
WHERE t.is_ms_shipped=0 AND t.name <> 'sysdiagrams' AND {{LAB_FILTER:s.t.tables}}
ORDER BY s.name, t.name;
"""

COLUMNS_SQL = """
SET NOCOUNT ON;
SELECT s.name, t.name, c.name, ty.name,
 c.max_length, c.precision, c.scale, c.is_nullable,
 CASE WHEN EXISTS (SELECT 1 FROM sys.indexes i JOIN sys.index_columns ic
   ON ic.object_id=i.object_id AND ic.index_id=i.index_id
   WHERE i.is_primary_key=1 AND i.object_id=t.object_id AND ic.column_id=c.column_id)
   THEN 1 ELSE 0 END,
 CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_key_columns fkc
   WHERE fkc.parent_object_id=t.object_id AND fkc.parent_column_id=c.column_id)
   THEN 1 ELSE 0 END
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
JOIN sys.columns c ON c.object_id=t.object_id
JOIN sys.types ty ON ty.user_type_id=c.user_type_id
WHERE t.is_ms_shipped=0 AND t.name <> 'sysdiagrams' AND {{LAB_FILTER:s.t.tables}}
ORDER BY s.name, t.name, c.column_id;
"""

INDEXES_SQL = """
SET NOCOUNT ON;
SELECT s.name, t.name, i.name, i.is_unique
FROM sys.indexes i JOIN sys.tables t ON t.object_id=i.object_id
JOIN sys.schemas s ON s.schema_id=t.schema_id
WHERE t.is_ms_shipped=0 AND t.name <> 'sysdiagrams' AND i.name IS NOT NULL AND {{LAB_FILTER:s.t.tables}}
ORDER BY s.name, t.name, i.name;
"""

LINKS_SQL = """
SET NOCOUNT ON;
SELECT sp.name + '.' + tp.name, sr.name + '.' + tr.name, fk.name,
 STUFF((SELECT ',' + c.name FROM sys.foreign_key_columns fkc
   JOIN sys.columns c ON c.object_id=fkc.parent_object_id AND c.column_id=fkc.parent_column_id
   WHERE fkc.constraint_object_id=fk.object_id ORDER BY fkc.constraint_column_id FOR XML PATH('')),1,1,''),
 STUFF((SELECT ',' + c.name FROM sys.foreign_key_columns fkc
   JOIN sys.columns c ON c.object_id=fkc.referenced_object_id AND c.column_id=fkc.referenced_column_id
   WHERE fkc.constraint_object_id=fk.object_id ORDER BY fkc.constraint_column_id FOR XML PATH('')),1,1,''),
 CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_key_columns fkc
   JOIN sys.columns c ON c.object_id=fkc.parent_object_id AND c.column_id=fkc.parent_column_id
   WHERE fkc.constraint_object_id=fk.object_id AND c.is_nullable=1) THEN 1 ELSE 0 END
FROM sys.foreign_keys fk
JOIN sys.tables tp ON tp.object_id=fk.parent_object_id
JOIN sys.schemas sp ON sp.schema_id=tp.schema_id
JOIN sys.tables tr ON tr.object_id=fk.referenced_object_id
JOIN sys.schemas sr ON sr.schema_id=tr.schema_id
WHERE tp.is_ms_shipped=0 AND tp.name <> 'sysdiagrams' AND {{LAB_FILTER:sp.tp.tables}}
ORDER BY fk.name;
"""


def rows(db: str, query: str) -> list[list[str]]:
    query = inventory_scope.expand_sql(query)
    out = subprocess.run(
        [SQLCMD, "-S", "localhost", "-E", "-C", "-d", db, "-h-1", "-W", "-s", "|", "-Q", query],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or out.stdout.strip())
    parsed = []
    for line in out.stdout.replace("\r", "").splitlines():
        line = line.strip()
        if not line or set(line) <= {"-", "|"}:
            continue
        parsed.append([cell.strip() for cell in line.split("|")])
    return parsed


def coltype(name: str, length: int, precision: int, scale: int) -> str:
    if name in ("varchar", "char", "varbinary", "binary"):
        return f"{name}({length if length != -1 else 'max'})"
    if name in ("nvarchar", "nchar"):
        return f"{name}({length // 2 if length != -1 else 'max'})"
    if name in ("decimal", "numeric"):
        return f"{name}({precision},{scale})"
    return name


def main() -> int:
    databases = [r[0] for r in rows("master", "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name LIKE 'AFS[_]%' AND state_desc='ONLINE' ORDER BY name;")]
    payload = {
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "databases": [],
        "domains": [],
        "totals": {},
    }
    domain_index: dict[str, dict] = {}
    total_tables = total_rows = total_fks = 0

    for db in databases:
        table_rows = rows(db, TABLES_SQL)
        column_rows = rows(db, COLUMNS_SQL)
        index_rows = rows(db, INDEXES_SQL)
        link_rows = rows(db, LINKS_SQL)

        tables = []
        by_key = {}
        schemas = sorted({r[0] for r in table_rows})
        for schema, name, count in table_rows:
            key = f"{schema}.{name}"
            domain_id = TABLE_DOMAIN.get(
                key,
                DOMAIN_MAP.get(schema, (schema, schema.title(), f"Objects in the {schema} schema."))[0],
            )
            table = {"key": key, "schema": schema, "name": name,
                     "rows": int(count or 0), "columns": [], "indexes": [],
                     "domain": domain_id, "x": 0, "y": 0, "h": 0}
            tables.append(table)
            by_key[key] = table

        for r in column_rows:
            schema, table, column, typ, length, precision, scale, nullable, pk, fk = r[:10]
            item = by_key.get(f"{schema}.{table}")
            if not item:
                continue
            item["columns"].append({
                "name": column,
                "type": coltype(typ, int(length), int(precision), int(scale)),
                "pk": pk == "1", "fk": fk == "1", "nullable": nullable == "1",
            })
        for r in index_rows:
            schema, table, name, unique = r[:4]
            item = by_key.get(f"{schema}.{table}")
            if item is not None:
                item["indexes"].append({"name": name, "unique": unique == "1"})

        links = []
        for r in link_rows:
            parent, ref, name, from_cols, to_cols, optional = r[:6]
            links.append({"from": parent, "to": ref, "name": name,
                          "fromCols": from_cols.split(","), "toCols": to_cols.split(","),
                          "optional": optional == "1"})

        views = int(rows(db, "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.views v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE v.is_ms_shipped=0 AND s.name <> 'paylab' AND v.name <> 'vw_EffectiveReading';")[0][0])
        procs = int(rows(db, "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.procedures p JOIN sys.schemas s ON s.schema_id=p.schema_id WHERE p.is_ms_shipped=0 AND p.name NOT LIKE 'sp[_]%diagram%' AND s.name <> 'paylab'
  AND p.name NOT IN ('usp_ValidateStaging','usp_ScoreCompleteness','usp_CorrectReading','usp_ResetQualityRun');")[0][0])
        functions = int(rows(db, "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF','FS','FT') AND is_ms_shipped=0 AND name NOT LIKE 'fn[_]diagram%';")[0][0])
        indexes = sum(len(t["indexes"]) for t in tables)
        db_rows = sum(t["rows"] for t in tables)

        for t in tables:
            key = t["key"]
            dom = DOMAIN_MAP.get(t["schema"], (t["schema"], t["schema"].title(), f"Objects in the {t['schema']} schema."))
            if key in TABLE_DOMAIN:
                dom = DOMAIN_MAP[TABLE_DOMAIN[key]]
            if dom[0] not in domain_index:
                domain_index[dom[0]] = {"id": dom[0], "label": dom[1], "description": dom[2], "tables": []}
            domain_index[dom[0]]["tables"].append(t["key"])

        payload["databases"].append({
            "name": db,
            "short": db.replace("AFS_", ""),
            "schemas": schemas,
            "tables": tables,
            "links": links,
            "width": 0, "height": 0,
            "counts": {"tables": len(tables), "views": views, "procedures": procs,
                       "functions": functions, "indexes": indexes,
                       "rows": db_rows, "foreignKeys": len(links)},
        })
        total_tables += len(tables)
        total_rows += db_rows
        total_fks += len(links)

    payload["domains"] = list(domain_index.values())
    payload["totals"] = {
        "databases": len(databases), "tables": total_tables,
        "views": sum(d["counts"]["views"] for d in payload["databases"]),
        "procedures": sum(d["counts"]["procedures"] for d in payload["databases"]),
        "functions": sum(d["counts"]["functions"] for d in payload["databases"]),
        "indexes": sum(d["counts"]["indexes"] for d in payload["databases"]),
        "foreignKeys": total_fks, "rows": total_rows,
        "domains": len(payload["domains"]),
    }

    text = EXPLORER.read_text(encoding="utf-8")
    line = "<script>window.AFS_DATA = " + json.dumps(payload, separators=(",", ":")) + ";</script>"
    text, count = __import__("re").subn(r"<script>window\.AFS_DATA = .*?;</script>", line, text, count=1, flags=__import__("re").S)
    if count != 1:
        raise SystemExit("could not find window.AFS_DATA in explorer.html")
    text = __import__("re").sub(r'Catalog (?:generated|refreshed)[^<]*', f"Catalog {payload['generatedAt'][:10]}", text, count=1)
    EXPLORER.write_text(text, encoding="utf-8")
    print(json.dumps(payload["totals"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
