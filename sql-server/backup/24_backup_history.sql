/*
  AFS-DBA-001
  Purpose: Read-only backup history and freshness report.
  Safety: Read-only.
*/

SET NOCOUNT ON;

;WITH Ranked AS
(
    SELECT
        bs.database_name,
        bs.type,
        bs.backup_finish_date,
        bs.backup_size / 1048576.0 AS size_mb,
        bs.is_damaged,
        bs.has_backup_checksums,
        mf.physical_device_name,
        ROW_NUMBER() OVER (PARTITION BY bs.database_name, bs.type ORDER BY bs.backup_finish_date DESC) AS rn
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name LIKE N'AFS[_]%'
)
SELECT database_name, type, backup_finish_date, size_mb, is_damaged,
       has_backup_checksums, physical_device_name
FROM Ranked
WHERE rn = 1
ORDER BY database_name, type;

-- Databases with no full backup in the last 7 days (or no full backup at all).
SELECT d.name AS database_name,
       MAX(bs.backup_finish_date) AS last_full_backup,
       CASE WHEN MAX(bs.backup_finish_date) IS NULL THEN 'NO_FULL_BACKUP'
            WHEN MAX(bs.backup_finish_date) < DATEADD(DAY, -7, SYSUTCDATETIME()) THEN 'OVERDUE'
            ELSE 'OK' END AS status
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS bs
  ON bs.database_name = d.name AND bs.type = 'D'
WHERE d.name LIKE N'AFS[_]%'
GROUP BY d.name
ORDER BY d.name;
GO
