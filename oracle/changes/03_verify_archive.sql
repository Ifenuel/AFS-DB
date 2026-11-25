SET PAGESIZE 100
SET LINESIZE 180
ALTER SYSTEM SWITCH LOGFILE;
SELECT TO_CHAR(completion_time,'HH24:MI:SS') done, sequence#, ROUND(blocks*block_size/1024/1024,2) mb FROM v$archived_log ORDER BY sequence#;
SELECT dest_name, status, destination, error FROM v$archive_dest_status WHERE dest_id = 1;
SELECT name, open_mode FROM v$pdbs ORDER BY con_id;
SELECT log_mode, open_mode FROM v$database;
