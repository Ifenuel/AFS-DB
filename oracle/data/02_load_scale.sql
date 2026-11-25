-- AFS-DBA-001
-- Purpose: Bring the Oracle portability lab to the same scale as the SQL Server core:
--          1,000 accounts, 20,000 transfers, 40,000 ledger entries, balances reconciled.
-- Safety: Replaces the contents of AFS_LAB.ACCOUNT and AFS_LAB.LEDGER_ENTRY.
-- Prerequisites: connected as AFS_LAB (or a DBA) in FREEPDB1.
-- Run as: AFS_LAB.

ALTER SESSION SET CURRENT_SCHEMA = AFS_LAB;
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

DELETE FROM ledger_entry;
DELETE FROM account;

INSERT INTO account (account_id, account_number, currency_code, balance, status)
SELECT LEVEL,
       LPAD(TO_CHAR(100000 + LEVEL), 12, '0'),
       'NGN',
       1000000,
       'ACTIVE'
FROM dual
CONNECT BY LEVEL <= 1000;

INSERT INTO ledger_entry (ledger_entry_id, account_id, entry_type, amount, occurred_at)
SELECT LEVEL * 2 - 1,
       MOD(LEVEL * 7, 1000) + 1,
       'DEBIT',
       100 + MOD(LEVEL * 37, 9000),
       SYSTIMESTAMP - NUMTODSINTERVAL(LEVEL, 'MINUTE')
FROM dual
CONNECT BY LEVEL <= 20000;

INSERT INTO ledger_entry (ledger_entry_id, account_id, entry_type, amount, occurred_at)
SELECT LEVEL * 2,
       MOD(LEVEL * 13, 1000) + 1,
       'CREDIT',
       100 + MOD(LEVEL * 37, 9000),
       SYSTIMESTAMP - NUMTODSINTERVAL(LEVEL, 'MINUTE')
FROM dual
CONNECT BY LEVEL <= 20000;

UPDATE account a
SET balance = 1000000 + NVL((SELECT SUM(CASE WHEN l.entry_type = 'CREDIT' THEN l.amount ELSE -l.amount END)
                   FROM ledger_entry l
                   WHERE l.account_id = a.account_id), 0);

COMMIT;

SELECT COUNT(*) AS accounts FROM account;
SELECT COUNT(*) AS ledger_entries FROM ledger_entry;
SELECT COUNT(*) AS balance_mismatches
FROM account a
WHERE a.balance <> 1000000 + NVL((SELECT SUM(CASE WHEN l.entry_type = 'CREDIT' THEN l.amount ELSE -l.amount END)
                        FROM ledger_entry l
                        WHERE l.account_id = a.account_id), 0);
EXIT
