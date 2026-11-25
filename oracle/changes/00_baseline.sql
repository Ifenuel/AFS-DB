-- AFS-DBA-001 | Oracle change ORCL-CHG-001 | step 0: baseline before any change
-- Run with: Invoke-OracleSql.ps1 -File oracle/changes/00_baseline.sql
SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK OFF

PROMPT === instance ===
SELECT instance_name, host_name, version, status FROM v$instance;

PROMPT === log mode ===
SELECT log_mode, open_mode, database_role, force_logging, flashback_on FROM v$database;

PROMPT === containers ===
SELECT con_id, name, open_mode FROM v$pdbs ORDER BY con_id;

PROMPT === recovery parameters ===
SELECT name, value FROM v$parameter
WHERE  name IN ('db_recovery_file_dest','db_recovery_file_dest_size',
                'remote_login_passwordfile','log_archive_format');

PROMPT === archive destinations ===
SELECT dest_id, status, destination, target FROM v$archive_dest WHERE status <> 'INACTIVE';

PROMPT === datafiles and size ===
SELECT ROUND(SUM(bytes)/1024/1024, 1) AS total_mb FROM v$datafile;

PROMPT === lab schema ===
SELECT owner, COUNT(*) AS objects FROM dba_objects
WHERE  owner = 'AFS_LAB' AND object_type IN ('TABLE','SEQUENCE','VIEW','PROCEDURE')
GROUP  BY owner;
