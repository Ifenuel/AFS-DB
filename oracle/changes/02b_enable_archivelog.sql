-- AFS-DBA-001 | ORCL-CHG-001 step 2b: enable ARCHIVELOG over a local bequeath connection
-- Run with -Local so STARTUP works while the instance is down (no listener needed).
SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK ON

-- A previous start left the instance in NOMOUNT; a clean restart makes this idempotent.
SHUTDOWN IMMEDIATE
STARTUP MOUNT

PROMPT === mode before the switch ===
SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS ts, log_mode, open_mode FROM v$database;

ALTER DATABASE ARCHIVELOG;

ALTER DATABASE OPEN;

PROMPT === mode after the switch ===
SELECT TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') AS ts, log_mode, open_mode FROM v$database;

ALTER SYSTEM SWITCH LOGFILE;

PROMPT === archived logs produced ===
SELECT TO_CHAR(completion_time,'HH24:MI:SS') AS completed, sequence#, ROUND(blocks*block_size/1024/1024, 2) AS mb, name
FROM   v$archived_log ORDER BY sequence#;

PROMPT === containers ===
SELECT con_id, name, open_mode FROM v$pdbs ORDER BY con_id;

PROMPT === archive destination in use ===
SELECT dest_name, status, destination FROM v$archive_dest_status WHERE status <> 'INACTIVE';
