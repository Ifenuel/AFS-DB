/*
  AFS-DBA-001
  Purpose: Read-only report of recent restore operations and durations.
  Safety: Read-only.
*/

SET NOCOUNT ON;

SELECT
    rh.destination_database_name,
    rh.restore_date,
    rh.restore_type,
    rh.user_name,
    bs.database_name AS source_database,
    bs.backup_finish_date,
    DATEDIFF(SECOND, bs.backup_finish_date, rh.restore_date) AS backup_age_seconds
FROM msdb.dbo.restorehistory AS rh
LEFT JOIN msdb.dbo.backupset AS bs
  ON bs.backup_set_id = rh.backup_set_id
WHERE rh.destination_database_name LIKE N'%RestoreTest%'
ORDER BY rh.restore_date DESC;
GO
