/*
  AFS-DBA-001
  Purpose: Update statistics for user tables in one database.
  Safety: Defaults to WHAT-IF. FULLSCAN is deliberately not the default because
          it can be expensive; use a sample and measure. Auto-update statistics
          remains enabled; this script is for targeted maintenance.
*/

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'AFS_CoreBanking';
DECLARE @WhatIf BIT = 1;
DECLARE @SamplePercent TINYINT = 20;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @SchemaName SYSNAME;
DECLARE @TableName SYSNAME;

IF DB_ID(@DatabaseName) IS NULL
    THROW 56020, N'Database does not exist.', 1;

IF @SamplePercent NOT BETWEEN 1 AND 100
    THROW 56021, N'Sample percent must be between 1 and 100.', 1;

CREATE TABLE #Actions
(
    SchemaName SYSNAME,
    TableName SYSNAME,
    Action NVARCHAR(400),
    Executed BIT
);

DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT s.name, t.name
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @SchemaName, @TableName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql =
        N'UPDATE STATISTICS ' + QUOTENAME(@DatabaseName) + N'.' +
        QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) +
        N' WITH SAMPLE ' + CONVERT(NVARCHAR(3), @SamplePercent) + N' PERCENT;';

    INSERT #Actions (SchemaName, TableName, Action, Executed)
    VALUES (@SchemaName, @TableName, @Sql, 0);

    IF @WhatIf = 0
    BEGIN
        PRINT @Sql;
        EXEC sys.sp_executesql @Sql;
        UPDATE #Actions SET Executed = 1
        WHERE SchemaName = @SchemaName AND TableName = @TableName;
    END

    FETCH NEXT FROM table_cursor INTO @SchemaName, @TableName;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;

SELECT * FROM #Actions ORDER BY SchemaName, TableName;
SELECT @WhatIf AS WhatIf, @SamplePercent AS SamplePercent, @DatabaseName AS DatabaseName;
GO
