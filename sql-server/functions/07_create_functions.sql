/*
  AFS-DBA-001
  Purpose: Inline table-valued function for account statements.
  Safety: Idempotent (CREATE OR ALTER). Read-only.
*/

USE [AFS_CoreBanking];
GO

CREATE OR ALTER FUNCTION account.ufn_AccountStatement
(
    @AccountId BIGINT,
    @FromUtc   DATETIME2(3) = NULL,
    @ToUtc     DATETIME2(3) = NULL
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        l.LedgerEntryId,
        l.TransferId,
        l.AccountId,
        l.EntryType,
        l.Amount,
        l.BalanceAfter,
        l.CurrencyCode,
        l.OccurredAt,
        l.Description
    FROM account.AccountLedgerEntry AS l
    WHERE l.AccountId = @AccountId
      AND l.OccurredAt >= ISNULL(@FromUtc, CONVERT(DATETIME2(3), '19000101'))
      AND l.OccurredAt <  ISNULL(@ToUtc,   CONVERT(DATETIME2(3), '99991231'))
);
GO

PRINT N'Account statement function created.';
GO
