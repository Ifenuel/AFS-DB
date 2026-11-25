# Test Inventory — AFS-DBA-001

**Status:** Test assets authored; database execution pending because SQL Server is not installed. The repository validator, Python generator and PowerShell syntax checks have actually run.

## 1. SQL Server tests

| Test ID | Objective | Script | Status |
|---|---|---|---|
| T-SCH-001 | All six databases exist | `sql-server/tests/01_schema_tests.sql` | Authored, not executed |
| T-SCH-002 | Required schemas/tables exist | same | Authored, not executed |
| T-SCH-003 | Procedures/functions/views compile and exist | same | Authored, not executed |
| T-SCH-004 | Reference data seeded | same | Authored, not executed |
| T-TXN-001 | Successful transfer posts debit/credit | `02_transfer_tests.sql` | Authored, not executed |
| T-TXN-002 | Duplicate RequestId is idempotent | same | Authored, not executed |
| T-TXN-003 | Insufficient funds rejected, no posting | same | Authored, not executed |
| T-TXN-004 | Inactive account rejected | same | Authored, not executed |
| T-TXN-005 | Invalid recipient rejected | same | Authored, not executed |
| T-TXN-006 | Forced failure after debit rolls back all changes | same | Authored, not executed |
| T-TXN-007 | Balance equals OpeningBalance + ledger sum for test accounts | same | Authored, not executed |
| T-TXN-008 | Failed transfer has audit event | same | Authored, not executed |
| T-TXN-009 | Concurrent opposite transfers do not deadlock/double-post | Manual two-session procedure (below) | Not executed |
| T-PAY-001 | Payment completes and posts once | `04_payment_tests.sql` | Authored, not executed |
| T-PAY-002 | Duplicate payment request is idempotent | same | Authored, not executed |
| T-PAY-003 | Payment failure is marked FAILED with no transfer | same | Authored, not executed |
| T-SEC-001..012 | Positive/negative permission checks | `03_security_tests.sql` | Authored, not executed |
| T-BAK-001 | Full backup + RESTORE VERIFYONLY | `sql-server/backup/20_backup_full.sql` | Authored, not executed |
| T-BAK-002 | Differential/log backup chain | `21`, `22` | Authored, not executed |
| T-REC-001 | Full restore to side database | `sql-server/recovery/30_restore_full_core.sql` | Authored, not executed |
| T-REC-002 | Point-in-time restore | `31_restore_log.sql` | Authored, not executed |
| T-REC-003 | DBCC CHECKDB + reconciliation after restore | `32_restore_verify.sql` | Authored, not executed |
| T-MON-001 | Health check returns expected checks | `sql-server/monitoring/40_health_check.sql` | Authored, not executed |
| T-MNT-001 | Index maintenance what-if output | `sql-server/maintenance/50_index_maintenance.sql` | Authored, not executed |
| T-MNT-002 | Integrity check | `51_integrity_check.sql` | Authored, not executed |

## 2. Non-database tests actually run

| Test ID | Objective | Command | Result |
|---|---|---|---|
| T-REPO-001 | Repository structure, links, JSON, Python syntax, SQL headers, secret scan | `python automation/python/validate_repo.py` | **PASS** (see evidence) |
| T-GEN-001 | Generate smoke dataset and record achieved volume | `python automation/python/generate_data.py --profile smoke ...` | **PASS**: 100 customers, 200 accounts, 992 transfers, 1,984 ledger entries, 300 payments, 50 cases, 500 audit events |
| T-PS-001 | PowerShell syntax parses | `Parser::ParseFile` | **PASS** for deployment/environment scripts |
| T-ENV-001 | Environment readiness | `Test-AfsEnvironment.ps1` | **Expected FAIL**: sqlcmd missing; account not elevated |
| T-DATA-001 | Generated CSV accounting reconciliation | Python check over `accounts.csv` + `ledger_entries.csv` | **PASS**: 200 accounts, 1,984 ledger entries, 0 mismatches for `OpeningBalance + ledger` |

## 3. Manual concurrency procedure

After SQL Server is installed, open two `sqlcmd`/SSMS sessions:

1. Session A: execute a transfer A→B inside an explicit transaction, then pause before commit (test harness).
2. Session B: execute a transfer B→A with a different RequestId.
3. Observe blocking/deadlock; capture `sys.dm_exec_requests` and `system_health`.
4. Confirm no partial postings; run `usp_ReconcileBalances` and `usp_ReconcileTransfers`.
5. Record the exact outputs and timings.

This is not automated in the current repository. Do not claim concurrency safety from the single-session tests.
