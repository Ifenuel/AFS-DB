# Apex Financial Services — database platform

A nine-database SQL Server estate covering a retail bank, with Oracle Database 26ai Free and MySQL
alongside it: schema, constraints, migration, indexing, backup, point-in-time recovery, privilege,
audit, monitoring and change control — each with output that can be inspected.

This is a working portfolio, not a product pitch. Figures on the site come from the running catalog;
security claims have a test that fails when the control is removed.

## What the estate contains

Pinned inventory snapshot: **25 November 2026, 17:20 UTC**. The snapshot is stored in
`site/data/inventory.json`; rebuild it with `python tools/audit/build_inventory.py --refresh`.

| Measure | Value |
|---|---|
| Engines | SQL Server 2025 Developer, Oracle Database 26ai Free, MySQL 8.4.9 |
| SQL Server databases | 9 — CoreBanking, Payments, Fraud, CustomerService, Audit, Reporting, Identity, Compliance, Archive |
| Tables / views / procedures | 64 / 11 / 9 |
| Declared foreign keys | 46, every one resolved to a live table |
| Rows | 199,904 generated test rows |
| Backup sets | 391 (65 full, 326 log) |
| Customers / accounts | 1,000 / 1,000 |
| Transfers / ledger entries | 20,000 / 40,000 |
| Balance invariant | `Balance = OpeningBalance + SUM(signed ledger)` — 0 mismatches |

Laboratory fixtures used by the investigations live in the same instance and are excluded from every
published count by one rule, `tools/audit/inventory_scope.py`.

## What is demonstrated

| Area | Evidence |
|---|---|
| Ledger integrity | Debit, credit, ledger event and audit row commit together; a request ID makes a replay settle once; reconciliation returns no unmatched rows across 20,000 transfers |
| Recovery | Checksum-verified full backups, 15-minute log chain, point-in-time restores executed on SQL Server and Oracle and compared row for row |
| Monitoring | An hourly health check that was deliberately broken to prove it raises CRITICAL and exits non-zero |
| Measured change | An index that changed nothing (6,700 reads) and a covering index that cut reads to 164 |
| Least privilege | An application with `CONTROL` reduced to procedure execution; direct writes denied (Msg 229); ledger writes attributed to the caller |
| Failure reproduction | Four documented industry failures reproduced, fixed and measured — 69/69 assertions |

The four investigations are published as individual pages under `site/case-p01.html` …
`site/case-p04.html`, with the register at `site/investigations.html`.

## Repository layout

```
site/                 static site (opens directly; no build step)
  assets/             stylesheet, scripts, per-database diagrams
  data/inventory.json pinned catalog snapshot used by every page
sql-server/           schema, migrations, procedures, labs and seeds
tools/                drivers for the investigations and inventory builders
evidence/             captured output and JSON results
automation/           site builder, audit and repository validation
```

## Running it

Requirements: SQL Server 2025 (Developer), Python 3.11+, `sqlcmd`, and optionally Oracle 26ai Free and
MySQL 8.4 for the cross-engine pages.

```bash
# rebuild the site pages from the pinned inventory
python automation/python/build_site_pages.py
python automation/python/build_case_pages.py

# serve the static site
cd site && python -m http.server 8781 --bind 127.0.0.1

# checks
python tools/audit_site.py
python automation/python/validate_repo.py
```

The investigations run against the live instance:

```bash
python tools/paylab/run_scenarios.py       # P-01 payment integrity
python tools/ot/run_quality.py --seconds 90 # P-02 telemetry quality (starts the PLC simulator)
python tools/labchange/run_scenarios.py    # P-03 change and recovery
python tools/security/run_security.py      # P-04 privileged access and audit
```

## Limits

The estate runs on one host with synthetic data. It shows that specific mechanisms produce specific
failures and that specific controls remove them under repeatable tests; it does not show production
scale, multi-host behaviour, network segmentation or endpoint detection. Each investigation page states
what it does not prove, and the research register grades every source, including three payment papers
that are conceptual and used for vocabulary only.

## Contact

Awoyo Emmanuel Ifeoluwa — [About and contact](site/about.html).

## Snapshot policy

Every published figure comes from `site/data/inventory.json`, captured on 25 November 2026 at
17:49 UTC. Test runs keep writing rows and backups, so the database has moved on since; the site
reports the capture, not the current instance. Refresh deliberately with
`python tools/audit/build_inventory.py --refresh`, then rebuild the pages — figures are never edited
by hand. Operational figures keep their own capture time.
