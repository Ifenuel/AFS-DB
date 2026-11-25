-- AFS-DBA-001
-- Purpose: MySQL smoke test for InnoDB transaction and constraint behavior.
-- Safety: Creates a dedicated afs_lab database; do not run on a shared instance.
-- Status: Executed 2026-11-25 on MySQL 8.4.9 Community Server;
--         evidence/verify/live/32_mysql_smoke.txt.

CREATE DATABASE IF NOT EXISTS afs_lab
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE afs_lab;

DROP TABLE IF EXISTS ledger_entry;
DROP TABLE IF EXISTS account;

CREATE TABLE account (
    account_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    account_number CHAR(12)        NOT NULL,
    currency_code  CHAR(3)         NOT NULL,
    balance        DECIMAL(19,4)   NOT NULL DEFAULT 0.0000,
    opening_balance DECIMAL(19,4)  NOT NULL DEFAULT 0.0000,
    overdraft_limit DECIMAL(19,4)  NOT NULL DEFAULT 0.0000,
    status         VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE',
    PRIMARY KEY (account_id),
    UNIQUE KEY uq_account_number (account_number),
    CONSTRAINT ck_account_balance CHECK (balance >= -overdraft_limit),
    CONSTRAINT ck_account_status CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED'))
) ENGINE=InnoDB;

CREATE TABLE ledger_entry (
    ledger_entry_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    account_id      BIGINT UNSIGNED NOT NULL,
    entry_type      VARCHAR(6)      NOT NULL,
    amount          DECIMAL(19,4)   NOT NULL,
    balance_after   DECIMAL(19,4)   NOT NULL,
    occurred_at     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)),
    PRIMARY KEY (ledger_entry_id),
    KEY ix_ledger_account_time (account_id, occurred_at),
    CONSTRAINT fk_ledger_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT ck_ledger_type CHECK (entry_type IN ('DEBIT', 'CREDIT')),
    CONSTRAINT ck_ledger_amount CHECK (amount <> 0)
) ENGINE=InnoDB;

INSERT INTO account (account_number, currency_code, balance, opening_balance)
VALUES ('ACC999999991', 'USD', 1000.0000, 1000.0000),
       ('ACC999999992', 'USD', 500.0000, 500.0000);

START TRANSACTION;
UPDATE account SET balance = balance - 100 WHERE account_number = 'ACC999999991';
UPDATE account SET balance = balance + 100 WHERE account_number = 'ACC999999992';
INSERT INTO ledger_entry (account_id, entry_type, amount, balance_after)
SELECT account_id, 'DEBIT', -100, 900 FROM account WHERE account_number = 'ACC999999991';
INSERT INTO ledger_entry (account_id, entry_type, amount, balance_after)
SELECT account_id, 'CREDIT', 100, 600 FROM account WHERE account_number = 'ACC999999992';
COMMIT;

SELECT a.account_number, a.opening_balance, a.balance,
       COALESCE(SUM(l.amount), 0) AS ledger_sum,
       a.opening_balance + COALESCE(SUM(l.amount), 0) AS expected_balance
FROM account AS a
LEFT JOIN ledger_entry AS l ON l.account_id = a.account_id
GROUP BY a.account_number, a.opening_balance, a.balance;

-- Expected: expected_balance equals balance for both accounts (0 mismatches).
-- The SQL Server lab remains the authoritative financial test.
