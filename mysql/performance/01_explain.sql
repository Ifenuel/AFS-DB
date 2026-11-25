-- AFS-DBA-001
-- Purpose: MySQL performance exercise using EXPLAIN/EXPLAIN ANALYZE.
-- Status: Executed 2026-11-25 on MySQL 8.4.9; evidence/verify/live/33_mysql_explain.txt.

USE afs_lab;

EXPLAIN
SELECT account_id, account_number, balance
FROM account
WHERE currency_code = 'USD'
  AND balance > 1000
ORDER BY balance DESC;

EXPLAIN ANALYZE
SELECT account_id, account_number, balance
FROM account
WHERE currency_code = 'USD'
  AND balance > 1000
ORDER BY balance DESC;

-- Add a candidate index only after measuring the baseline:
-- CREATE INDEX ix_account_currency_balance ON account (currency_code, balance);
-- Re-run EXPLAIN and compare rows examined, access type, and actual time.
