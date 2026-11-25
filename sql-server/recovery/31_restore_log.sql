/*
  AFS-DBA-001
  Purpose: Apply a differential or transaction log backup to the restore-test
           database. Supports point-in-time recovery with @StopAt.
  Safety: Target is restricted to AFS_CoreBanking_RestoreTest.
  SQLCMD variables: BackupFile, StopAt (optional ISO-8601 UTC string), IsLog (1/0)
*/

SET NOCOUNT ON;

DECLARE @BackupFile NVARCHAR(500) = N'$(BackupFile)';
DECLARE @StopAt NVARCHAR(30) = N'$(StopAt)';
DECLARE @IsLog BIT = TRY_CONVERT(BIT, N'$(IsLog)');
DECLARE @TargetDatabase SYSNAME = N'AFS_CoreBanking_RestoreTest';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF @TargetDatabase = N'AFS_CoreBanking'
    THROW 55002, N'Refusing to restore over the live Core Banking database.', 1;

IF @BackupFile IS NULL OR LEN(LTRIM(RTRIM(@BackupFile))) = 0
    THROW 55003, N'BackupFile is required.', 1;

SET @Sql =
    CASE WHEN @IsLog = 1 THEN N'RESTORE LOG ' ELSE N'RESTORE DATABASE ' END
    + QUOTENAME(@TargetDatabase)
    + N' FROM DISK = N''' + REPLACE(@BackupFile, '''', '''''') + N''''
    + N' WITH '
    + CASE
        WHEN @StopAt IS NULL OR LEN(LTRIM(RTRIM(@StopAt))) = 0
            THEN N'RECOVERY'
        ELSE N'RECOVERY, STOPAT = N''' + REPLACE(@StopAt, '''', '''''') + N''''
      END
    + N', CHECKSUM, STATS = 10;';

PRINT @Sql;
EXEC sys.sp_executesql @Sql;

SELECT @TargetDatabase AS TargetDatabase,
       CASE WHEN @IsLog = 1 THEN 'LOG' ELSE 'DIFFERENTIAL' END AS BackupType,
       @StopAt AS StopAtRequested,
       @StartedAt AS RestoreStartedAtUtc, SYSUTCDATETIME() AS RestoreCompletedAtUtc;
GO
