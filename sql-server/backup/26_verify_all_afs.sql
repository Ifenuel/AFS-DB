/*
  AFS-DBA-001
  Purpose: VERIFYONLY every AFS database's most recent FULL backup, read from
           msdb rather than from a hand-written file list, so the check cannot
           silently omit a database added to the estate after the job was built.
  Safety:  Read-only against backup media. Restores nothing.
  Output:  One line per database: backup set, finish time, file, verification.
  Run as:  A member of sysadmin or db_owner with msdb read access.
*/

SET NOCOUNT ON;

DECLARE @db SYSNAME, @path NVARCHAR(500), @finish DATETIME, @size DECIMAL(19,2);
DECLARE @checked INT = 0, @failed INT = 0, @missing INT = 0;

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE name LIKE N'AFS[_]%' AND state_desc = N'ONLINE'
    ORDER BY name;

CREATE TABLE #Result
(
    DatabaseName SYSNAME,
    BackupFinish DATETIME NULL,
    FilePath     NVARCHAR(500) NULL,
    VerifyResult VARCHAR(20) NOT NULL,
    Message      NVARCHAR(400) NULL
);

OPEN dbs;
FETCH NEXT FROM dbs INTO @db;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @path = NULL;
    SET @finish = NULL;

    SELECT TOP (1)
        @path = mf.physical_device_name,
        @finish = bs.backup_finish_date
    FROM msdb.dbo.backupset AS bs
    JOIN msdb.dbo.backupmediafamily AS mf
      ON mf.media_set_id = bs.media_set_id
    WHERE bs.database_name = @db
      AND bs.type = 'D'
    ORDER BY bs.backup_finish_date DESC;

    IF @path IS NULL
    BEGIN
        INSERT #Result VALUES (@db, NULL, NULL, 'MISSING', N'No FULL backup in msdb');
        SET @missing += 1;
    END
    ELSE
    BEGIN
        BEGIN TRY
            RESTORE VERIFYONLY FROM DISK = @path WITH CHECKSUM;
            INSERT #Result VALUES (@db, @finish, @path, 'VERIFIED', N'RESTORE VERIFYONLY WITH CHECKSUM succeeded');
            SET @checked += 1;
        END TRY
        BEGIN CATCH
            INSERT #Result VALUES (@db, @finish, @path, 'FAILED', ERROR_MESSAGE());
            SET @failed += 1;
        END CATCH
    END

    FETCH NEXT FROM dbs INTO @db;
END

CLOSE dbs;
DEALLOCATE dbs;

SELECT DatabaseName, CONVERT(VARCHAR(19), BackupFinish, 120) AS BackupFinish,
       VerifyResult, FilePath, Message
FROM #Result
ORDER BY DatabaseName;

SELECT COUNT(*) AS databases_total,
       SUM(CASE WHEN VerifyResult = 'VERIFIED' THEN 1 ELSE 0 END) AS verified,
       SUM(CASE WHEN VerifyResult = 'FAILED'   THEN 1 ELSE 0 END) AS failed,
       SUM(CASE WHEN VerifyResult = 'MISSING'  THEN 1 ELSE 0 END) AS missing
FROM #Result;

DROP TABLE #Result;
