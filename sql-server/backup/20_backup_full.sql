/*
  AFS-DBA-001
  Purpose: Full backup with CHECKSUM and COMPRESSION, followed by RESTORE VERIFYONLY.
  Safety: Creates a new timestamped file; does not delete anything.
  Prerequisites: Database exists; backup folder exists and is writable by the SQL
                 Server service account; AFS_Audit.operational.BackupHistory exists.
  SQLCMD variables: DatabaseName, BackupRoot
  Run as: AFS_DBA or AFS_Ops with backup permission.
*/

-- BackupRoot is supplied by sqlcmd -v; do not add a :setvar default.
SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'$(DatabaseName)';
DECLARE @BackupRoot NVARCHAR(400) = N'$(BackupRoot)';
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Stamp VARCHAR(20) =
    CONVERT(CHAR(8), @Now, 112) + 'T' + REPLACE(CONVERT(CHAR(8), @Now, 108), ':', '') + 'Z';
DECLARE @BackupPath NVARCHAR(500) =
    CONCAT(@BackupRoot, '\', @DatabaseName, '\AFS_', @DatabaseName, '_FULL_', @Stamp, '.bak');
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF DB_ID(@DatabaseName) IS NULL
    THROW 54000, N'Database does not exist.', 1;

BEGIN TRY
    BACKUP DATABASE @DatabaseName
    TO DISK = @BackupPath
    WITH CHECKSUM, COMPRESSION, STATS = 10,
         NAME = N'AFS full backup';

    RESTORE VERIFYONLY
    FROM DISK = @BackupPath
    WITH CHECKSUM;

    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, SizeMB, IsVerified, VerificationTime)
        SELECT @DatabaseName, 'FULL', @BackupPath, @StartedAt, SYSUTCDATETIME(),
               CAST(SUM(backup_size) / 1048576.0 AS DECIMAL(19,2)), 1, SYSUTCDATETIME()
        FROM msdb.dbo.backupset
        WHERE database_name = @DatabaseName
          AND backup_finish_date >= @StartedAt;
    END TRY
    BEGIN CATCH
        PRINT N'Backup succeeded, but audit history insert failed: ' + ERROR_MESSAGE();
    END CATCH;

    SELECT @DatabaseName AS DatabaseName, 'FULL' AS BackupType,
           @BackupPath AS BackupPath, 'VERIFIED' AS Verification;
END TRY
BEGIN CATCH
    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, IsVerified, Message)
        VALUES (@DatabaseName, 'FULL', @BackupPath, @StartedAt, SYSUTCDATETIME(), 0,
                LEFT(ERROR_MESSAGE(), 4000));
    END TRY
    BEGIN CATCH
        PRINT N'Backup failure history insert also failed: ' + ERROR_MESSAGE();
    END CATCH;

    THROW;
END CATCH
GO
