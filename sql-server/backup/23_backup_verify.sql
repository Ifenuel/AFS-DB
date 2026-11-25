/*
  AFS-DBA-001
  Purpose: Verify one backup file without restoring it.
  Safety: Read-only with respect to the database; reads the backup file.
  SQLCMD variables: BackupFile
  Note: RESTORE VERIFYONLY proves the backup set is readable and complete.
        It does not prove logical data consistency; a restore + DBCC CHECKDB is
        required for that.
*/

SET NOCOUNT ON;

DECLARE @BackupFile NVARCHAR(500) = N'$(BackupFile)';

IF @BackupFile IS NULL OR LEN(LTRIM(RTRIM(@BackupFile))) = 0
    THROW 54004, N'BackupFile is required.', 1;

RESTORE VERIFYONLY
FROM DISK = @BackupFile
WITH CHECKSUM;

SELECT @BackupFile AS BackupFile, 'VERIFIED' AS Verification,
       SYSUTCDATETIME() AS VerifiedAtUtc;
GO
