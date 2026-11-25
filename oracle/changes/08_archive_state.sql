-- AFS-DBA-001 | ORCL-CHG-001 step 5: archive state immediately before the PDB PITR
SET PAGESIZE 100
SET LINESIZE 180

ALTER SYSTEM SWITCH LOGFILE;

SELECT log_mode, open_mode, TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS now_time FROM v$database;
SELECT name, open_mode FROM v$pdbs ORDER BY con_id;
SELECT sequence#, TO_CHAR(completion_time,'YYYY-MM-DD HH24:MI:SS') archived_at,
       ROUND(blocks*block_size/1024/1024,2) mb
  FROM v$archived_log ORDER BY sequence#;
SELECT dest_name, status, error FROM v$archive_dest_status WHERE dest_id = 1;

ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT COUNT(*) AS marker_rows_before_recovery FROM AFS_LAB.RECOVERY_MARKER;
