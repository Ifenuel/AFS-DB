/*
  AFS-DBA-001
  Purpose: Run DBCC CHECKDB for one AFS database with clear output.
  Safety: Read-only consistency check; can be I/O and CPU intensive. Run in a
          maintenance window for large databases. Does not repair anything.
*/

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'AFS_CoreBanking';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF DB_ID(@DatabaseName) IS NULL
    THROW 56010, N'Database does not exist.', 1;

SET @Sql = N'DBCC CHECKDB (' + QUOTENAME(@DatabaseName) + N') WITH NO_INFOMSGS, ALL_ERRORMSGS, DATA_PURITY;';
PRINT @Sql;
EXEC sys.sp_executesql @Sql;

SELECT @DatabaseName AS DatabaseName, 'CHECKDB_COMPLETED' AS Status,
       @StartedAt AS StartedAtUtc, SYSUTCDATETIME() AS CompletedAtUtc,
       DATEDIFF(SECOND, @StartedAt, SYSUTCDATETIME()) AS DurationSeconds;
GO
