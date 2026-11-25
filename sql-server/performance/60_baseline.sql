/*
  AFS-DBA-001
  Purpose: Capture a repeatable performance baseline before changes.
  Safety: Read-only DMV queries. Save the output with a timestamp; do not edit it
          to make a later comparison look better.
  Prerequisites: VIEW SERVER STATE; workload has run so query stats are populated.
*/

SET NOCOUNT ON;

SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128)) AS Edition,
    CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(64)) AS ProductVersion,
    CAST(SERVERPROPERTY('Collation') AS NVARCHAR(128)) AS Collation,
    SYSUTCDATETIME() AS CapturedAtUtc;

SELECT
    cpu_count,
    scheduler_count,
    physical_memory_kb / 1024.0 / 1024.0 AS PhysicalMemoryGB,
    sqlserver_start_time,
    DATEDIFF(HOUR, sqlserver_start_time, SYSUTCDATETIME()) AS UptimeHours
FROM sys.dm_os_sys_info;

SELECT
    physical_memory_in_use_kb / 1024.0 AS SqlMemoryInUseMB,
    large_page_allocations_kb / 1024.0 AS LargePageAllocationsMB,
    locked_page_allocations_kb / 1024.0 AS LockedPageAllocationsMB
FROM sys.dm_os_process_memory;

SELECT TOP (20)
    wait_type,
    wait_time_ms,
    waiting_tasks_count,
    signal_wait_time_ms,
    wait_time_ms / NULLIF(waiting_tasks_count, 0) AS AvgWaitMs
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN
(
    'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE', 'SLEEP_TASK',
    'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR', 'LOGMGR_QUEUE',
    'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
    'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT'
)
ORDER BY wait_time_ms DESC;

SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.type_desc,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(19,2)) AS SizeMB,
    vfs.num_of_reads,
    vfs.num_of_bytes_read / 1048576.0 AS ReadMB,
    vfs.io_stall_read_ms,
    vfs.num_of_writes,
    vfs.num_of_bytes_written / 1048576.0 AS WrittenMB,
    vfs.io_stall_write_ms
FROM sys.master_files AS mf
CROSS APPLY sys.dm_io_virtual_file_stats(mf.database_id, mf.file_id) AS vfs
WHERE mf.database_id IN (SELECT database_id FROM sys.databases WHERE name LIKE N'AFS[_]%')
ORDER BY DatabaseName, mf.type_desc, mf.file_id;

SELECT TOP (20)
    qs.execution_count,
    qs.total_elapsed_time / 1000.0 AS TotalElapsedMs,
    qs.total_worker_time / 1000.0 AS TotalCpuMs,
    qs.total_logical_reads,
    qs.total_physical_reads,
    qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000.0 AS AvgElapsedMs,
    qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS AvgLogicalReads,
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1) AS StatementText,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_elapsed_time DESC;

-- Query Store, if enabled on the database.
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'AFS_CoreBanking' AND is_query_store_on = 1)
BEGIN
    SELECT TOP (20)
        q.query_id,
        qt.query_sql_text,
        rs.count_executions,
        rs.avg_duration / 1000.0 AS AvgDurationMs,
        rs.avg_logical_io_reads,
        rs.avg_cpu_time / 1000.0 AS AvgCpuMs
    FROM AFS_CoreBanking.sys.query_store_query AS q
    JOIN AFS_CoreBanking.sys.query_store_query_text AS qt
      ON qt.query_text_id = q.query_text_id
    JOIN AFS_CoreBanking.sys.query_store_plan AS p
      ON p.query_id = q.query_id
    JOIN AFS_CoreBanking.sys.query_store_runtime_stats AS rs
      ON rs.plan_id = p.plan_id
    ORDER BY rs.avg_duration DESC;
END
GO
