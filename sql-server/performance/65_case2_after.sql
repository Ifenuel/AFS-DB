/*
  AFS-DBA-001
  Purpose: Case 2 after - rewrite the predicate as a range so the optimizer can
           seek on CompletedAt.
  Safety: Read-only. The query returns the same logical day in UTC.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
SET STATISTICS IO, TIME ON;

DECLARE @DayStart DATETIME2(3) =
    CONVERT(DATETIME2(3), CONVERT(DATE, DATEADD(DAY, -1, SYSUTCDATETIME())));
DECLARE @DayEnd DATETIME2(3) = DATEADD(DAY, 1, @DayStart);

SELECT TOP (100)
    t.TransferId,
    t.Amount,
    t.CurrencyCode,
    t.CompletedAt
FROM account.Transfer AS t
WHERE t.CompletedAt >= @DayStart
  AND t.CompletedAt <  @DayEnd
ORDER BY t.CompletedAt DESC;

SET STATISTICS IO, TIME OFF;
GO
