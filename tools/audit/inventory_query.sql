/*
  AFS-DBA-001 — authoritative SQL Server inventory
  One row per AFS database. Object counts are qualified per database: the
  earlier version of this query ran sys.tables in the master context and
  silently reported zero tables, which is exactly the class of counting error
  this audit exists to remove.
  Counting rules:
    tables     user tables, excluding dbo.sysdiagrams support tables
    views      user views
    procedures user procedures, excluding the seven sp_*diagram helpers
    rows       SUM(sys.partitions.rows) for heap/clustered indexes
    exclusion  laboratory fixtures are not application objects. The single rule
               lives in tools/audit/inventory_scope.py and is expanded into the
               {{LAB_FILTER:...}} placeholders below before execution.
*/
SET NOCOUNT ON;

DECLARE @sql nvarchar(max) = N'';

SELECT @sql = STRING_AGG(CONVERT(nvarchar(max),
    N'SELECT N''' + name + N''' AS db, state_desc, recovery_model_desc,
      (SELECT COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.tables t
        JOIN ' + QUOTENAME(name) + N'.sys.schemas s ON s.schema_id = t.schema_id
        WHERE t.is_ms_shipped = 0 AND t.name <> N''sysdiagrams''
          AND {{LAB_FILTER:s.t.tables}}) AS tables,
      (SELECT COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.views v
        JOIN ' + QUOTENAME(name) + N'.sys.schemas s ON s.schema_id = v.schema_id
        WHERE v.is_ms_shipped = 0 AND {{LAB_FILTER:s.v.views}}) AS views,
      (SELECT COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.procedures p
        JOIN ' + QUOTENAME(name) + N'.sys.schemas s ON s.schema_id = p.schema_id
        WHERE p.is_ms_shipped = 0 AND p.name NOT LIKE N''sp[_]%diagram%''
          AND {{LAB_FILTER:s.p.procedures}}) AS procedures,
      (SELECT COUNT(*) FROM ' + QUOTENAME(name) + N'.sys.foreign_keys fk
        JOIN ' + QUOTENAME(name) + N'.sys.tables pt ON pt.object_id = fk.parent_object_id
        JOIN ' + QUOTENAME(name) + N'.sys.schemas ps ON ps.schema_id = pt.schema_id
        WHERE {{LAB_FILTER:ps.pt.tables}}) AS foreign_keys,
      (SELECT SUM(p.rows) FROM ' + QUOTENAME(name) + N'.sys.partitions p
        JOIN ' + QUOTENAME(name) + N'.sys.tables t2 ON t2.object_id = p.object_id
        JOIN ' + QUOTENAME(name) + N'.sys.schemas s2 ON s2.schema_id = t2.schema_id
        WHERE p.index_id IN (0,1) AND t2.is_ms_shipped = 0
          AND {{LAB_FILTER:s2.t2.tables}}) AS rows,
      (SELECT CAST(SUM(size) * 8.0 / 1024 AS decimal(10,1))
        FROM ' + QUOTENAME(name) + N'.sys.database_files) AS size_mb,
      (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b
        WHERE b.database_name = N''' + name + N''' AND b.type = ''D'') AS last_full,
      (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b
        WHERE b.database_name = N''' + name + N''' AND b.type = ''L'') AS last_log,
      (SELECT COUNT(*) FROM msdb.dbo.backupset b
        WHERE b.database_name = N''' + name + N''' AND b.type = ''D'') AS full_sets,
      (SELECT COUNT(*) FROM msdb.dbo.backupset b
        WHERE b.database_name = N''' + name + N''' AND b.type = ''L'') AS log_sets
    FROM sys.databases WHERE name = N''' + name + N''''), N' UNION ALL ')
FROM sys.databases
WHERE name LIKE N'AFS[_]%' AND state_desc = N'ONLINE';

SET @sql = N'SELECT * FROM (' + @sql + N') x ORDER BY db';
EXEC (@sql);
