/*
  AFS-DBA-001
  Purpose: Fragmentation-aware rowstore index maintenance for one database.
  Safety: Defaults to WHAT-IF. Rebuild/reorganize only when @WhatIf = 0.
          Online rebuild is used where supported; it can still consume CPU,
          tempdb and log, so run in a maintenance window and monitor.
  SQLCMD variables: none. Parameters are T-SQL variables below.
*/

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'AFS_CoreBanking';
DECLARE @WhatIf BIT = 1;              -- change to 0 only after reviewing output
DECLARE @RebuildThreshold DECIMAL(5,2) = 30.0;
DECLARE @ReorganizeThreshold DECIMAL(5,2) = 10.0;
DECLARE @MinPageCount BIGINT = 1000;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @SchemaName SYSNAME;
DECLARE @TableName SYSNAME;
DECLARE @IndexName SYSNAME;
DECLARE @Fragmentation DECIMAL(5,2);
DECLARE @PageCount BIGINT;
DECLARE @Action VARCHAR(20);

IF DB_ID(@DatabaseName) IS NULL
    THROW 56000, N'Database does not exist.', 1;

CREATE TABLE #Actions
(
    SchemaName SYSNAME,
    TableName SYSNAME,
    IndexName SYSNAME,
    FragmentationPercent DECIMAL(5,2),
    PageCount BIGINT,
    Action VARCHAR(20),
    Executed BIT
);

DECLARE index_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    s.name,
    t.name,
    i.name,
    ips.avg_fragmentation_in_percent,
    ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(@DatabaseName), NULL, NULL, NULL, 'LIMITED') AS ips
JOIN sys.indexes AS i
  ON i.object_id = ips.object_id AND i.index_id = ips.index_id
JOIN sys.tables AS t
  ON t.object_id = i.object_id
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
WHERE i.type IN (1, 2)          -- clustered/nonclustered rowstore
  AND i.is_disabled = 0
  AND i.is_hypothetical = 0
  AND ips.page_count >= @MinPageCount
  AND ips.avg_fragmentation_in_percent >= @ReorganizeThreshold
ORDER BY ips.avg_fragmentation_in_percent DESC;

OPEN index_cursor;
FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Action = CASE WHEN @Fragmentation >= @RebuildThreshold THEN 'REBUILD' ELSE 'REORGANIZE' END;

    INSERT #Actions (SchemaName, TableName, IndexName, FragmentationPercent, PageCount, Action, Executed)
    VALUES (@SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount, @Action, 0);

    IF @WhatIf = 0
    BEGIN
        SET @Sql =
            CASE WHEN @Action = 'REBUILD'
                 THEN N'ALTER INDEX ' + QUOTENAME(@IndexName) + N' ON ' +
                      QUOTENAME(@DatabaseName) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) +
                      N' REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);'
                 ELSE N'ALTER INDEX ' + QUOTENAME(@IndexName) + N' ON ' +
                      QUOTENAME(@DatabaseName) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) +
                      N' REORGANIZE;'
            END;

        PRINT @Sql;
        EXEC sys.sp_executesql @Sql;

        UPDATE #Actions
        SET Executed = 1
        WHERE SchemaName = @SchemaName AND TableName = @TableName AND IndexName = @IndexName;
    END

    FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation, @PageCount;
END

CLOSE index_cursor;
DEALLOCATE index_cursor;

SELECT * FROM #Actions ORDER BY FragmentationPercent DESC;
SELECT @WhatIf AS WhatIf, @DatabaseName AS DatabaseName,
       @RebuildThreshold AS RebuildThreshold, @ReorganizeThreshold AS ReorganizeThreshold;
GO
