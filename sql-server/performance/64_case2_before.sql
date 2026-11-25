/*
  AFS-DBA-001
  Purpose: Case 2 baseline - a non-SARGable date predicate.
  Safety: Read-only.
  The predicate applies CONVERT to the indexed column, which commonly prevents
  a seek. Capture the actual plan; do not claim a scan without checking.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
SET STATISTICS IO, TIME ON;

DECLARE @Day DATE = CONVERT(DATE, DATEADD(DAY, -1, SYSUTCDATETIME()));

SELECT TOP (100)
    t.TransferId,
    t.Amount,
    t.CurrencyCode,
    t.CompletedAt
FROM account.Transfer AS t
WHERE CONVERT(DATE, t.CompletedAt) = @Day
ORDER BY t.CompletedAt DESC;

SET STATISTICS IO, TIME OFF;
GO
