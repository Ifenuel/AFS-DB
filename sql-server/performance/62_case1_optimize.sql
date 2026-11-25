/*
  AFS-DBA-001
  Purpose: Case 1 optimization - add an index for (CurrencyCode, CompletedAt).
  Safety: Creates an index only if it does not exist. Online rebuild requires an
          edition that supports it (Developer does). Review write overhead after
          the change; an index is not free.
  Change record: CR-002 (index change) should be completed before applying this
  in a controlled environment.
*/

USE [AFS_CoreBanking];
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_account_Transfer_Currency_CompletedAt'
      AND object_id = OBJECT_ID(N'account.Transfer')
)
BEGIN
    CREATE INDEX IX_account_Transfer_Currency_CompletedAt
        ON account.Transfer (CurrencyCode, CompletedAt)
        INCLUDE (FromAccountId, ToAccountId, Amount)
        WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);
    PRINT N'Created IX_account_Transfer_Currency_CompletedAt.';
END
ELSE
    PRINT N'Index already exists; no change.';
GO
