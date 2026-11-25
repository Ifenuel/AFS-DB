/*
  AFS-DBA-001
  Purpose: Prove the three governance databases are restorable, not just
           backed up. Each latest FULL backup is restored under a scratch name
           with MOVE, compared to the live database, then dropped.
  Safety:  Creates only AFS_<name>_RESTORE scratch databases. Does not touch
           the live copies; each scratch copy is dropped at the end.
  Run as:  sysadmin or dbcreator.
*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Proof') IS NOT NULL DROP TABLE #Proof;
CREATE TABLE #Proof
(
    DatabaseName SYSNAME,
    LiveTables INT, RestoredTables INT,
    LiveRows BIGINT, RestoredRows BIGINT,
    LiveDetail VARCHAR(60), RestoredDetail VARCHAR(60),
    Result VARCHAR(20)
);

DECLARE @db SYSNAME, @path NVARCHAR(500), @scratch SYSNAME;
DECLARE @mdf NVARCHAR(400), @ldf NVARCHAR(400), @sql NVARCHAR(MAX);
DECLARE @liveRows BIGINT, @restRows BIGINT, @liveTabs INT, @restTabs INT;
DECLARE @liveDetail VARCHAR(60), @restDetail VARCHAR(60);
DECLARE @detailSchema SYSNAME, @detailTable SYSNAME;

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.name FROM (VALUES
        (N'AFS_Identity'),
        (N'AFS_Compliance'),
        (N'AFS_Archive')
    ) AS v(name)
    ORDER BY v.name;

DECLARE @detail TABLE (db SYSNAME, object_name SYSNAME);
INSERT @detail VALUES
    (N'AFS_Identity',   N'iam.Principal'),
    (N'AFS_Compliance', N'grc.ControlTest'),
    (N'AFS_Archive',    N'retention.ArchivedRecord');

OPEN dbs;
FETCH NEXT FROM dbs INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @scratch = @db + N'_RESTORE';
    SET @path = NULL;

    SELECT TOP (1) @path = mf.physical_device_name
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name = @db AND bs.type = 'D'
    ORDER BY bs.backup_finish_date DESC;

    IF @path IS NULL
    BEGIN
        INSERT #Proof VALUES (@db, NULL, NULL, NULL, NULL, NULL, NULL, 'NO BACKUP');
        FETCH NEXT FROM dbs INTO @db;
        CONTINUE;
    END

    IF DB_ID(@scratch) IS NOT NULL
    BEGIN
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@scratch) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@scratch) + N';';
        EXEC (@sql);
    END

    SET @mdf = N'C:\AFS\Data\' + @scratch + N'.mdf';
    SET @ldf = N'C:\AFS\Data\' + @scratch + N'_log.ldf';

    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@scratch) + N' FROM DISK = N'''
             + REPLACE(@path, N'''', N'''''') + N''' WITH MOVE N''' + @db + N''' TO N'''
             + @mdf + N''', MOVE N''' + @db + N'_log'' TO N''' + @ldf
             + N''', RECOVERY, REPLACE, STATS = 25;';
    EXEC (@sql);

    -- Compare table count and total rows.
    SET @sql = N'SELECT @t = COUNT(*), @r = SUM(p.rows)
                 FROM ' + QUOTENAME(@db) + N'.sys.tables t
                 JOIN ' + QUOTENAME(@db) + N'.sys.partitions p
                   ON p.object_id = t.object_id AND p.index_id IN (0,1)
                 WHERE t.is_ms_shipped = 0;';
    EXEC sp_executesql @sql, N'@t INT OUTPUT, @r BIGINT OUTPUT', @liveTabs OUTPUT, @liveRows OUTPUT;

    SET @sql = N'SELECT @t = COUNT(*), @r = SUM(p.rows)
                 FROM ' + QUOTENAME(@scratch) + N'.sys.tables t
                 JOIN ' + QUOTENAME(@scratch) + N'.sys.partitions p
                   ON p.object_id = t.object_id AND p.index_id IN (0,1)
                 WHERE t.is_ms_shipped = 0;';
    EXEC sp_executesql @sql, N'@t INT OUTPUT, @r BIGINT OUTPUT', @restTabs OUTPUT, @restRows OUTPUT;

    -- Compare one named table so the proof is not only an aggregate.
    SELECT @detailSchema = PARSENAME(object_name, 2), @detailTable = PARSENAME(object_name, 1)
    FROM @detail WHERE db = @db;

    SET @sql = N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@db) + N'.'
             + QUOTENAME(@detailSchema) + N'.' + QUOTENAME(@detailTable) + N';';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @liveDetail OUTPUT;

    SET @sql = N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@scratch) + N'.'
             + QUOTENAME(@detailSchema) + N'.' + QUOTENAME(@detailTable) + N';';
    EXEC sp_executesql @sql, N'@c INT OUTPUT', @restDetail OUTPUT;

    INSERT #Proof
    VALUES (@db, @liveTabs, @restTabs, @liveRows, @restRows,
            CONVERT(VARCHAR(60), @liveDetail), CONVERT(VARCHAR(60), @restDetail),
            CASE WHEN @liveTabs = @restTabs AND @liveRows = @restRows
                       AND @liveDetail = @restDetail AND @liveDetail IS NOT NULL
                 THEN 'IDENTICAL' ELSE 'MISMATCH' END);

    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@scratch) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@scratch) + N';';
    EXEC (@sql);

    FETCH NEXT FROM dbs INTO @db;
END

CLOSE dbs;
DEALLOCATE dbs;

SELECT DatabaseName, LiveTables, RestoredTables, LiveRows, RestoredRows,
       LiveDetail AS LiveDetailRows, RestoredDetail AS RestoredDetailRows, Result
FROM #Proof ORDER BY DatabaseName;

SELECT COUNT(*) AS databases_tested,
       SUM(CASE WHEN Result = 'IDENTICAL' THEN 1 ELSE 0 END) AS identical,
       SUM(CASE WHEN Result <> 'IDENTICAL' THEN 1 ELSE 0 END) AS not_identical
FROM #Proof;

DROP TABLE #Proof;
