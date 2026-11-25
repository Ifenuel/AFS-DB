/*
  AFS-DBA-001
  Purpose: Baseline for Case 1 - recent transfers by currency.
  Safety: Read-only. SET STATISTICS IO/TIME affects only this session.
  Expected before state: no index keyed by (CurrencyCode, CompletedAt); the plan
  may scan or use an account-based index and sort. Do not assume; capture the plan.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
SET STATISTICS IO, TIME ON;

DECLARE @Since DATETIME2(3) = DATEADD(DAY, -30, SYSUTCDATETIME());

SELECT TOP (100)
    t.TransferId,
    t.FromAccountId,
    t.ToAccountId,
    t.Amount,
    t.CurrencyCode,
    t.CompletedAt
FROM account.Transfer AS t
WHERE t.CurrencyCode = 'USD'
  AND t.CompletedAt >= @Since
ORDER BY t.CompletedAt DESC;

SET STATISTICS IO, TIME OFF;
GO
