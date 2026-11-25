-- AFS-DBA-001
-- Purpose: Oracle execution-plan/index exercise (authored, not executed).
-- Run as: AFS_LAB.

EXPLAIN PLAN FOR
SELECT account_id, account_number, balance
FROM account
WHERE currency_code = 'USD'
  AND balance > 1000
ORDER BY balance DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);

-- Candidate index after measuring the baseline:
-- CREATE INDEX ix_account_currency_balance ON account (currency_code, balance);
-- Re-run EXPLAIN PLAN and compare access path, cost, and rows.

-- In Oracle, statistics freshness matters as much as the index. Check:
-- SELECT table_name, last_analyzed, num_rows FROM user_tables;
-- EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'ACCOUNT');
