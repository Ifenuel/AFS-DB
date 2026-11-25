/*
  AFS-DBA-001
  Purpose: Daily health snapshot for the AFS databases.
  Safety: Read-only DMV/metadata queries. Short-lived; may briefly block on
          catalog metadata but does not modify user data.
  Prerequisites: VIEW SERVER STATE (AFS_DBA); msdb access for job/backup history.
  Output: A severity table followed by detail result sets. A non-OK severity
          means a human must investigate; this script does not fix anything.
*/

SET NOCOUNT ON;

DECLARE @Checks TABLE
(
    CheckId    VARCHAR(60)  NOT NULL,
    Severity   VARCHAR(10)  NOT NULL,
    CheckName  NVARCHAR(200) NOT NULL,
    Details    NVARCHAR(1000) NULL,
    CheckedAt  DATETIME2(3) NOT NULL DEFAULT (SYSUTCDATETIME())
);

-- Instance availability is implied by this script running. Record it explicitly.
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT 'INSTANCE', 'OK', 'SQL Server instance reachable',
       CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128)) + N' / ' +
       CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));

-- Database state.
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'DB_STATE_' + d.name,
    CASE WHEN d.state_desc <> 'ONLINE' THEN 'CRITICAL' ELSE 'OK' END,
    N'Database state: ' + d.name,
    d.state_desc + N' / recovery=' + d.recovery_model_desc +
    N' / log_reuse_wait=' + d.log_reuse_wait_desc
FROM sys.databases AS d
WHERE d.name LIKE N'AFS[_]%';

-- Disk free space for volumes hosting AFS files.
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'DISK_' + vs.volume_mount_point,
    CASE
        WHEN MIN(vs.available_bytes) / 1073741824.0 < 10 THEN 'CRITICAL'
        WHEN MIN(vs.available_bytes) / 1073741824.0 < 20 THEN 'WARNING'
        ELSE 'OK'
    END,
    N'Disk free space on ' + vs.volume_mount_point,
    CAST(CAST(MIN(vs.available_bytes) / 1073741824.0 AS DECIMAL(10,2)) AS NVARCHAR(20)) + N' GB free of ' +
    CAST(CAST(MIN(vs.total_bytes) / 1073741824.0 AS DECIMAL(10,2)) AS NVARCHAR(20)) + N' GB'
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE mf.database_id IN
(
    SELECT database_id FROM sys.databases WHERE name LIKE N'AFS[_]%'
)
GROUP BY vs.volume_mount_point;

-- Full backup freshness.
;WITH LastFull AS
(
    SELECT database_name, MAX(backup_finish_date) AS last_full
    FROM msdb.dbo.backupset
    WHERE type = 'D'
    GROUP BY database_name
)
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'BACKUP_FULL_' + d.name,
    CASE
        WHEN lf.last_full IS NULL THEN 'CRITICAL'
        WHEN lf.last_full < DATEADD(DAY, -14, SYSUTCDATETIME()) THEN 'CRITICAL'
        WHEN lf.last_full < DATEADD(DAY, -7, SYSUTCDATETIME()) THEN 'WARNING'
        ELSE 'OK'
    END,
    N'Full backup freshness: ' + d.name,
    COALESCE(CONVERT(NVARCHAR(30), lf.last_full, 126), N'NO FULL BACKUP')
FROM sys.databases AS d
LEFT JOIN LastFull AS lf ON lf.database_name = d.name
WHERE d.name LIKE N'AFS[_]%';

-- Log backup freshness for FULL-recovery AFS databases.
;WITH LastLog AS
(
    SELECT database_name, MAX(backup_finish_date) AS last_log
    FROM msdb.dbo.backupset
    WHERE type = 'L'
    GROUP BY database_name
)
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'BACKUP_LOG_' + d.name,
    CASE
        WHEN ll.last_log IS NULL THEN 'CRITICAL'
        WHEN ll.last_log < DATEADD(HOUR, -2, SYSUTCDATETIME()) THEN 'CRITICAL'
        WHEN ll.last_log < DATEADD(MINUTE, -30, SYSUTCDATETIME()) THEN 'WARNING'
        ELSE 'OK'
    END,
    N'Log backup freshness: ' + d.name,
    COALESCE(CONVERT(NVARCHAR(30), ll.last_log, 126), N'NO LOG BACKUP')
FROM sys.databases AS d
LEFT JOIN LastLog AS ll ON ll.database_name = d.name
WHERE d.name LIKE N'AFS[_]%'
  AND d.recovery_model_desc = N'FULL';

-- Agent job last outcome.
;WITH LastJob AS
(
    SELECT
        j.name,
        h.run_status,
        msdb.dbo.agent_datetime(h.run_date, h.run_time) AS last_run,
        ROW_NUMBER() OVER (PARTITION BY j.job_id ORDER BY h.run_date DESC, h.run_time DESC) AS rn
    FROM msdb.dbo.sysjobs AS j
    JOIN msdb.dbo.sysjobhistory AS h
      ON h.job_id = j.job_id
     AND h.step_id = 0
)
INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'JOB_' + lj.name,
    CASE
        WHEN lj.run_status = 0 THEN 'CRITICAL'
        WHEN lj.run_status = 2 THEN 'WARNING'
        WHEN lj.run_status = 3 THEN 'WARNING'
        ELSE 'OK'
    END,
    N'Agent job: ' + lj.name,
    N'last run ' + COALESCE(CONVERT(NVARCHAR(30), lj.last_run, 126), N'unknown') +
    N', run_status=' + CONVERT(NVARCHAR(10), lj.run_status)
FROM LastJob AS lj
WHERE lj.rn = 1;

-- Blocking.
DECLARE @BlockedSessions INT =
(
    SELECT COUNT(*) FROM sys.dm_exec_requests
    WHERE blocking_session_id <> 0 AND session_id <> @@SPID
);
INSERT @Checks (CheckId, Severity, CheckName, Details)
VALUES
(
    'BLOCKING',
    CASE WHEN @BlockedSessions > 20 THEN 'CRITICAL'
         WHEN @BlockedSessions > 0 THEN 'WARNING' ELSE 'OK' END,
    N'Blocked sessions',
    CONVERT(NVARCHAR(20), @BlockedSessions) + N' blocked session(s)'
);

-- Long-running non-background requests.
DECLARE @LongQueries INT =
(
    SELECT COUNT(*) FROM sys.dm_exec_requests
    WHERE session_id <> @@SPID
      AND status <> 'background'
      AND total_elapsed_time > 60000
);
INSERT @Checks (CheckId, Severity, CheckName, Details)
VALUES
(
    'LONG_QUERIES',
    CASE WHEN @LongQueries > 5 THEN 'CRITICAL'
         WHEN @LongQueries > 0 THEN 'WARNING' ELSE 'OK' END,
    N'Requests running longer than 60 seconds',
    CONVERT(NVARCHAR(20), @LongQueries) + N' request(s)'
);

-- Transaction log usage via DBCC SQLPERF (all databases).
CREATE TABLE #LogSpace
(
    DatabaseName sysname,
    LogSizeMB float,
    LogSpaceUsedPercent float,
    Status int
);
INSERT #LogSpace
EXEC (N'DBCC SQLPERF(LOGSPACE)');

INSERT @Checks (CheckId, Severity, CheckName, Details)
SELECT
    'LOG_USAGE_' + DatabaseName,
    CASE WHEN LogSpaceUsedPercent >= 90 THEN 'CRITICAL'
         WHEN LogSpaceUsedPercent >= 70 THEN 'WARNING' ELSE 'OK' END,
    N'Transaction log usage: ' + DatabaseName,
    CAST(CAST(LogSpaceUsedPercent AS DECIMAL(5,2)) AS NVARCHAR(10)) + N'% used, ' +
    CAST(CAST(LogSizeMB AS DECIMAL(10,2)) AS NVARCHAR(20)) + N' MB'
FROM #LogSpace
WHERE DatabaseName LIKE N'AFS[_]%';

-- Deadlock reports retained in system_health (count only; recency is investigated separately).
DECLARE @DeadlockCount INT = 0;
SELECT @DeadlockCount = COUNT(*)
FROM
(
    SELECT CAST(st.target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets AS st
    JOIN sys.dm_xe_sessions AS s ON s.address = st.event_session_address
    WHERE s.name = N'system_health'
      AND st.target_name = N'ring_buffer'
) AS x
CROSS APPLY x.target_data.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS n(e);

INSERT @Checks (CheckId, Severity, CheckName, Details)
VALUES
(
    'DEADLOCKS',
    CASE WHEN @DeadlockCount > 0 THEN 'WARNING' ELSE 'OK' END,
    N'Deadlock reports in system_health',
    CONVERT(NVARCHAR(20), @DeadlockCount) + N' retained deadlock report(s)'
);

-- Overall summary first.
SELECT
    CASE
        WHEN EXISTS (SELECT 1 FROM @Checks WHERE Severity = 'CRITICAL') THEN 'CRITICAL'
        WHEN EXISTS (SELECT 1 FROM @Checks WHERE Severity = 'WARNING') THEN 'WARNING'
        ELSE 'OK'
    END AS OverallStatus,
    SUM(CASE WHEN Severity = 'CRITICAL' THEN 1 ELSE 0 END) AS CriticalChecks,
    SUM(CASE WHEN Severity = 'WARNING' THEN 1 ELSE 0 END) AS WarningChecks,
    SUM(CASE WHEN Severity = 'OK' THEN 1 ELSE 0 END) AS OkChecks,
    SYSUTCDATETIME() AS CheckedAtUtc
FROM @Checks;

SELECT CheckId, Severity, CheckName, Details, CheckedAt
FROM @Checks
ORDER BY CASE Severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
         CheckId;

-- Detail: database files and sizes.
SELECT
    DB_NAME(mf.database_id) AS DatabaseName,
    mf.name AS LogicalFileName,
    mf.physical_name AS PhysicalFileName,
    mf.type_desc AS FileType,
    CAST(mf.size * 8.0 / 1024 AS DECIMAL(19,2)) AS SizeMB,
    mf.growth,
    mf.is_percent_growth,
    mf.is_read_only
FROM sys.master_files AS mf
WHERE mf.database_id IN (SELECT database_id FROM sys.databases WHERE name LIKE N'AFS[_]%')
ORDER BY DatabaseName, mf.type_desc, mf.file_id;

-- Detail: currently blocking.
SELECT
    r.session_id,
    r.blocking_session_id,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time,
    r.total_elapsed_time,
    DB_NAME(r.database_id) AS DatabaseName,
    SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text)
          ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1) AS CurrentStatement
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
  AND r.session_id <> @@SPID;

-- Detail: long-running requests.
SELECT
    r.session_id,
    r.status,
    r.command,
    r.wait_type,
    r.total_elapsed_time,
    r.cpu_time,
    r.logical_reads,
    DB_NAME(r.database_id) AS DatabaseName,
    t.text AS SqlText
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID
  AND r.status <> 'background'
  AND r.total_elapsed_time > 60000
ORDER BY r.total_elapsed_time DESC;

-- Detail: top wait types (cumulative since instance start).
SELECT TOP (10)
    wait_type,
    wait_time_ms,
    waiting_tasks_count,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN
(
    'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE', 'SLEEP_TASK',
    'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR', 'LOGMGR_QUEUE',
    'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
    'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT'
)
ORDER BY wait_time_ms DESC;

DROP TABLE #LogSpace;
GO
