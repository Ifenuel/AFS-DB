/*
  AFS-DBA-001
  Purpose: Protective FULL backup of every AFS database, each verified with
           RESTORE VERIFYONLY, before any environment change (instance install,
           file relocation, migration, restore drill).
  Safety:  Creates new timestamped files only. Drops nothing, restores nothing,
           overwrites no existing database.
  Notes:  Self-contained (no sqlcmd variables) so any client can run it.
          Creates the per-database backup subfolder if it is missing.
          Tries backup compression and falls back to an uncompressed backup,
          because SQL Server Express / LocalDB reject WITH COMPRESSION.
  Run as: A member of the sysadmin/db_owner role on the instance.
*/

SET NOCOUNT ON;

DECLARE @BackupRoot NVARCHAR(400) = N'C:\AFS\Backups';
DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Stamp VARCHAR(20) =
    CONVERT(CHAR(8), @Now, 112) + 'T' + REPLACE(CONVERT(CHAR(8), @Now, 108), ':', '') + 'Z';

DECLARE @Targets TABLE (DatabaseName SYSNAME PRIMARY KEY);
INSERT @Targets (DatabaseName)
VALUES (N'AFS_CoreBanking'), (N'AFS_Payments'), (N'AFS_CustomerService'),
       (N'AFS_Audit'), (N'AFS_Reporting'), (N'AFS_Fraud');

DECLARE @Results TABLE (
    DatabaseName SYSNAME,
    BackupType   VARCHAR(10),
    BackupPath   NVARCHAR(500),
    SizeMB       DECIMAL(19,2),
    Verification VARCHAR(20),
    Message      NVARCHAR(4000)
);

DECLARE @db SYSNAME, @folder NVARCHAR(500), @path NVARCHAR(500), @sql NVARCHAR(1000);

DECLARE backup_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName FROM @Targets ORDER BY DatabaseName;

OPEN backup_cursor;
FETCH NEXT FROM backup_cursor INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
    BEGIN
        INSERT @Results VALUES (@db, 'FULL', NULL, NULL, 'SKIPPED', N'Database does not exist.');
        FETCH NEXT FROM backup_cursor INTO @db;
        CONTINUE;
    END

    SET @folder = CONCAT(@BackupRoot, N'\', @db);
    SET @path   = CONCAT(@folder, N'\AFS_', @db, N'_FULL_', @Stamp, N'.bak');

    BEGIN TRY
        -- BACKUP fails if the target folder is missing; create it defensively.
        IF NOT EXISTS (SELECT 1 FROM sys.dm_os_file_exists(@folder))
        BEGIN
            SET @sql = N'EXEC master.dbo.xp_create_subdir N''' + REPLACE(@folder, N'''', N'''''') + N''';';
            EXEC (@sql);
        END

        -- Compression is not available on Express/LocalDB, so retry plainly.
        BEGIN TRY
            BACKUP DATABASE @db
                TO DISK = @path
                WITH CHECKSUM, COMPRESSION, INIT, STATS = 25,
                     NAME = N'AFS protective full backup';
        END TRY
        BEGIN CATCH
            BACKUP DATABASE @db
                TO DISK = @path
                WITH CHECKSUM, INIT, STATS = 25,
                     NAME = N'AFS protective full backup (uncompressed)';
        END CATCH

        RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM;

        INSERT @Results
        SELECT TOP (1) @db, 'FULL', @path,
               CAST(backup_size / 1048576.0 AS DECIMAL(19,2)),
               'VERIFIED', N'Backup written and checksum-verified.'
        FROM msdb.dbo.backupset
        WHERE database_name = @db AND backup_finish_date >= @Now
        ORDER BY backup_finish_date DESC;
    END TRY
    BEGIN CATCH
        INSERT @Results VALUES (@db, 'FULL', @path, NULL, 'FAILED', ERROR_MESSAGE());
    END CATCH

    FETCH NEXT FROM backup_cursor INTO @db;
END

CLOSE backup_cursor;
DEALLOCATE backup_cursor;

SELECT DatabaseName, BackupType, SizeMB, Verification, BackupPath, Message
FROM @Results
ORDER BY DatabaseName;

SELECT COUNT(DISTINCT DatabaseName) AS DatabasesVerified
FROM @Results WHERE Verification = 'VERIFIED';

SELECT COUNT(*) AS Failures
FROM @Results WHERE Verification = 'FAILED';
GO
