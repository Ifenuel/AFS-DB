/*
  AFS-DBA-001
  Purpose: Verify a restored database logically: DBCC CHECKDB then reconciliation.
  Safety: Read-only checks on the restore-test database.
*/

SET NOCOUNT ON;

DECLARE @TargetDatabase SYSNAME = N'AFS_CoreBanking_RestoreTest';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF DB_ID(@TargetDatabase) IS NULL
    THROW 55004, N'Restore-test database does not exist.', 1;

SET @Sql = N'DBCC CHECKDB (' + QUOTENAME(@TargetDatabase) + N') WITH NO_INFOMSGS, ALL_ERRORMSGS;';
EXEC sys.sp_executesql @Sql;

SET @Sql =
    N'USE ' + QUOTENAME(@TargetDatabase) + N'; ' +
    N'EXEC account.usp_ReconcileBalances; ' +
    N'EXEC account.usp_ReconcileTransfers;';
EXEC sys.sp_executesql @Sql;

SELECT @TargetDatabase AS TargetDatabase, 'CHECKDB_AND_RECONCILIATION_COMPLETED' AS Status,
       @StartedAt AS StartedAtUtc, SYSUTCDATETIME() AS CompletedAtUtc;
GO
