-- AFS-DBA-001 | ORCL-CHG-001 step 2: switch the database to ARCHIVELOG
-- Downtime window: one clean shutdown and open. No data files are touched.
-- Rollback: SHUTDOWN IMMEDIATE; STARTUP MOUNT; ALTER DATABASE NOARCHIVELOG; ALTER DATABASE OPEN;
SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK ON

PROMPT === before ===
SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS ts, log_mode FROM v$database;

SHUTDOWN IMMEDIATE
STARTUP MOUNT

ALTER DATABASE ARCHIVELOG;

ALTER DATABASE OPEN;

PROMPT === after ===
SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS ts, log_mode, open_mode FROM v$database;

PROMPT === force a log switch so an archived log exists ===
ALTER SYSTEM SWITCH LOGFILE;

SELECT TO_CHAR(completion_time,'HH24:MI:SS') AS completed,
       sequence#, name, ROUND(blocks*block_size/1024/1024, 2) AS mb
FROM   v$archived_log
ORDER  BY sequence#;

PROMPT === containers still open ===
SELECT con_id, name, open_mode FROM v$pdbs ORDER BY con_id;
