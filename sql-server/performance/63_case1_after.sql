/*
  AFS-DBA-001
  Purpose: Case 1 after measurement. Run the identical query used in
           61_case1_before.sql on the same data and hardware.
  Safety: Read-only.
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
