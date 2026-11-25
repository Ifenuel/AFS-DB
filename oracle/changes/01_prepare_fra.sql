-- AFS-DBA-001 | ORCL-CHG-001 step 1: configure a Fast Recovery Area (SPFILE, takes effect on restart)
-- ARCHIVELOG needs a destination that survives a restart; LOG_ARCHIVE_DEST_1 currently
-- points at the Oracle Home, which is not a safe place for redo.
SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK ON

ALTER SYSTEM SET db_recovery_file_dest_size = '6G' SCOPE = SPFILE;
ALTER SYSTEM SET db_recovery_file_dest     = 'C:\app\oraclelab\fast_recovery_area' SCOPE = SPFILE;
ALTER SYSTEM SET log_archive_dest_1         = 'LOCATION=USE_DB_RECOVERY_FILE_DEST' SCOPE = SPFILE;

PROMPT === spfile values now ===
SELECT name, value FROM v$spparameter
WHERE  name IN ('db_recovery_file_dest','db_recovery_file_dest_size','log_archive_dest_1')
ORDER  BY name;
