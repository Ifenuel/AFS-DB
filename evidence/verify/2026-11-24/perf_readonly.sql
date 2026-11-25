-- Read-only performance remeasurement on Developer AFS_CoreBanking
-- Query 1 baseline (non-SARGable): YEAR/MONTH on CompletedAt
-- Query 2 optimised (SARGable): half-open range
-- Run with SET STATISTICS IO, TIME ON in SSMS; here we capture via DMVs + SHOWPLAN.
USE [AFS_CoreBanking];
SET NOCOUNT ON;

-- Estimated plans (compile only, no execution beyond compile)
SET SHOWPLAN_XML ON;
SELECT COUNT_BIG(*) FROM account.Transfer WHERE YEAR(CompletedAt) = 2026 AND MONTH(CompletedAt) = 11;
SELECT COUNT_BIG(*) FROM account.Transfer WHERE CompletedAt >= '2026-11-01' AND CompletedAt < '2026-12-01';
SET SHOWPLAN_XML OFF;
