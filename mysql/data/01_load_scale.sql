-- AFS-DBA-001
-- Purpose: Bring the MySQL portability lab to the same scale as the SQL Server core:
--          1,000 accounts, 20,000 transfers, 40,000 ledger entries, balances reconciled.
-- Safety: Replaces the contents of afs_lab.account and afs_lab.ledger_entry.
-- Prerequisites: afs_lab schema with account and ledger_entry (see mysql/installation).
-- Run as: a user with INSERT/UPDATE/DELETE on afs_lab.

SET SESSION cte_max_recursion_depth = 100000;
USE afs_lab;
START TRANSACTION;

DELETE FROM ledger_entry;
DELETE FROM account;
ALTER TABLE ledger_entry AUTO_INCREMENT = 1;
ALTER TABLE account AUTO_INCREMENT = 1;

INSERT INTO account (account_number, currency_code, balance, opening_balance, overdraft_limit, status)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)
SELECT LPAD(CAST(100000 + i AS CHAR), 12, '0'), 'NGN', 0,
       500000 + (i * 137) % 250000, 0, 'ACTIVE'
FROM n;

INSERT INTO ledger_entry (account_id, entry_type, amount, balance_after, occurred_at)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
SELECT CASE WHEN side.s = 'D' THEN ((n.i * 7) % 1000) + 1 ELSE ((n.i * 13) % 1000) + 1 END,
       CASE WHEN side.s = 'D' THEN 'DEBIT' ELSE 'CREDIT' END,
       100 + (n.i * 37) % 9000,
       0,
       TIMESTAMP('2026-01-01 00:00:00') + INTERVAL n.i MINUTE
FROM n
JOIN (SELECT 'D' AS s UNION ALL SELECT 'C') AS side;

UPDATE account a
JOIN (
    SELECT account_id,
           SUM(CASE WHEN entry_type = 'CREDIT' THEN amount ELSE -amount END) AS net
    FROM ledger_entry
    GROUP BY account_id
) t ON t.account_id = a.account_id
SET a.balance = a.opening_balance + t.net;

UPDATE ledger_entry l
JOIN (
    SELECT le.ledger_entry_id,
           a.opening_balance + SUM(CASE WHEN le.entry_type = 'CREDIT' THEN le.amount ELSE -le.amount END)
               OVER (PARTITION BY le.account_id ORDER BY le.ledger_entry_id) AS running
    FROM ledger_entry le
    JOIN account a ON a.account_id = le.account_id
) x ON x.ledger_entry_id = l.ledger_entry_id
SET l.balance_after = x.running;

COMMIT;
