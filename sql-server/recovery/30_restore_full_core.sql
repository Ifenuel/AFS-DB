/*
  AFS-DBA-001
  Purpose: Restore a full backup of AFS_CoreBanking to a separate database for
           a recovery drill. Leaves the target in NORECOVERY so differential and
           log backups can be applied.
  Safety: REPLACE is used only on the explicitly named *_RestoreTest database.
          This script must not be pointed at AFS_CoreBanking.
  SQLCMD variables: BackupFile, DataRoot, LogRoot
  Prerequisites: Backup file exists; target database is not the live database.
*/

-- DataRoot, LogRoot and BackupRoot are supplied by sqlcmd -v.

SET NOCOUNT ON;

DECLARE @BackupFile NVARCHAR(500) = N'$(BackupFile)';
DECLARE @TargetDatabase SYSNAME = N'AFS_CoreBanking_RestoreTest';
DECLARE @DataFile NVARCHAR(500) = N'$(DataRoot)\AFS_CoreBanking_RestoreTest.mdf';
DECLARE @LogFile NVARCHAR(500) = N'$(LogRoot)\AFS_CoreBanking_RestoreTest.ldf';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF @TargetDatabase = N'AFS_CoreBanking'
    THROW 55000, N'Refusing to restore over the live Core Banking database.', 1;

IF @BackupFile IS NULL OR LEN(LTRIM(RTRIM(@BackupFile))) = 0
    THROW 55001, N'BackupFile is required.', 1;

SET @Sql =
    N'RESTORE DATABASE ' + QUOTENAME(@TargetDatabase) +
    N' FROM DISK = N''' + REPLACE(@BackupFile, '''', '''''') + N'''' +
    N' WITH MOVE N''AFS_CoreBanking'' TO N''' + REPLACE(@DataFile, '''', '''''') + N'''' +
    N', MOVE N''AFS_CoreBanking_log'' TO N''' + REPLACE(@LogFile, '''', '''''') + N'''' +
    N', NORECOVERY, REPLACE, CHECKSUM, STATS = 10;';

PRINT @Sql;
EXEC sys.sp_executesql @Sql;

SELECT @TargetDatabase AS TargetDatabase, 'FULL_RESTORED_NORECOVERY' AS Status,
       @StartedAt AS RestoreStartedAtUtc, SYSUTCDATETIME() AS RestoreCompletedAtUtc;
GO
