/*
  AFS-DBA-001
  Purpose: Differential backup with CHECKSUM/COMPRESSION and RESTORE VERIFYONLY.
  Safety: Creates a new timestamped file; does not delete anything.
  SQLCMD variables: DatabaseName, BackupRoot
*/

-- BackupRoot and DatabaseName are supplied by sqlcmd -v.

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'$(DatabaseName)';
DECLARE @BackupRoot NVARCHAR(400) = N'$(BackupRoot)';
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Stamp VARCHAR(20) =
    CONVERT(CHAR(8), @Now, 112) + 'T' + REPLACE(CONVERT(CHAR(8), @Now, 108), ':', '') + 'Z';
DECLARE @BackupPath NVARCHAR(500) =
    CONCAT(@BackupRoot, '\', @DatabaseName, '\AFS_', @DatabaseName, '_DIFF_', @Stamp, '.bak');
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF DB_ID(@DatabaseName) IS NULL
    THROW 54001, N'Database does not exist.', 1;

BEGIN TRY
    BACKUP DATABASE @DatabaseName
    TO DISK = @BackupPath
    WITH DIFFERENTIAL, CHECKSUM, COMPRESSION, STATS = 10,
         NAME = N'AFS differential backup';

    RESTORE VERIFYONLY
    FROM DISK = @BackupPath
    WITH CHECKSUM;

    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, SizeMB, IsVerified, VerificationTime)
        SELECT @DatabaseName, 'DIFFERENTIAL', @BackupPath, @StartedAt, SYSUTCDATETIME(),
               CAST(SUM(backup_size) / 1048576.0 AS DECIMAL(19,2)), 1, SYSUTCDATETIME()
        FROM msdb.dbo.backupset
        WHERE database_name = @DatabaseName
          AND backup_finish_date >= @StartedAt;
    END TRY
    BEGIN CATCH
        PRINT N'Backup succeeded, but audit history insert failed: ' + ERROR_MESSAGE();
    END CATCH;

    SELECT @DatabaseName AS DatabaseName, 'DIFFERENTIAL' AS BackupType,
           @BackupPath AS BackupPath, 'VERIFIED' AS Verification;
END TRY
BEGIN CATCH
    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, IsVerified, Message)
        VALUES (@DatabaseName, 'DIFFERENTIAL', @BackupPath, @StartedAt, SYSUTCDATETIME(), 0,
                LEFT(ERROR_MESSAGE(), 4000));
    END TRY
    BEGIN CATCH
        PRINT N'Backup failure history insert also failed: ' + ERROR_MESSAGE();
    END CATCH;

    THROW;
END CATCH
GO
