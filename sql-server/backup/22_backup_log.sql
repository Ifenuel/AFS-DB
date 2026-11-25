/*
  AFS-DBA-001
  Purpose: Transaction log backup with CHECKSUM/COMPRESSION and verification.
  Safety: Creates a new timestamped file. Requires FULL recovery model.
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
    CONCAT(@BackupRoot, '\', @DatabaseName, '\AFS_', @DatabaseName, '_LOG_', @Stamp, '.trn');
DECLARE @StartedAt DATETIME2(3) = SYSUTCDATETIME();

IF DB_ID(@DatabaseName) IS NULL
    THROW 54002, N'Database does not exist.', 1;

IF (SELECT recovery_model_desc FROM sys.databases WHERE name = @DatabaseName) <> 'FULL'
    THROW 54003, N'Transaction log backup requires the FULL recovery model.', 1;

BEGIN TRY
    BACKUP LOG @DatabaseName
    TO DISK = @BackupPath
    WITH CHECKSUM, COMPRESSION, STATS = 10,
         NAME = N'AFS transaction log backup';

    RESTORE VERIFYONLY
    FROM DISK = @BackupPath
    WITH CHECKSUM;

    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, SizeMB, IsVerified, VerificationTime)
        SELECT @DatabaseName, 'LOG', @BackupPath, @StartedAt, SYSUTCDATETIME(),
               CAST(SUM(backup_size) / 1048576.0 AS DECIMAL(19,2)), 1, SYSUTCDATETIME()
        FROM msdb.dbo.backupset
        WHERE database_name = @DatabaseName
          AND backup_finish_date >= @StartedAt;
    END TRY
    BEGIN CATCH
        PRINT N'Backup succeeded, but audit history insert failed: ' + ERROR_MESSAGE();
    END CATCH;

    SELECT @DatabaseName AS DatabaseName, 'LOG' AS BackupType,
           @BackupPath AS BackupPath, 'VERIFIED' AS Verification;
END TRY
BEGIN CATCH
    BEGIN TRY
        INSERT AFS_Audit.operational.BackupHistory
            (DatabaseName, BackupType, BackupPath, StartedAt, CompletedAt, IsVerified, Message)
        VALUES (@DatabaseName, 'LOG', @BackupPath, @StartedAt, SYSUTCDATETIME(), 0,
                LEFT(ERROR_MESSAGE(), 4000));
    END TRY
    BEGIN CATCH
        PRINT N'Backup failure history insert also failed: ' + ERROR_MESSAGE();
    END CATCH;

    THROW;
END CATCH
GO
