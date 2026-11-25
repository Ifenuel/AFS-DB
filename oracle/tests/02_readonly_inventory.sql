-- Read-only Oracle inventory (no changes)
SET ECHO ON;
SELECT banner FROM v$version;
SELECT name, open_mode, database_role FROM v$database;
SELECT log_mode FROM v$database;
SELECT instance_name, version, status FROM v$instance;
SELECT con_id, name, open_mode FROM v$pdbs;
SELECT parameter, value FROM v$parameter WHERE name IN ('db_block_size','sga_target','pga_aggregate_target','processes','sessions','undo_tablespaces');
SELECT tablespace_name, status, block_size FROM dba_tablespaces ORDER BY tablespace_name;
SELECT username, account_status, default_tablespace FROM dba_users WHERE username='AFS_LAB';
SELECT privilege FROM dba_sys_privs WHERE grantee='AFS_LAB' ORDER BY privilege;
SELECT owner, table_name, num_rows FROM dba_tables WHERE owner='AFS_LAB' ORDER BY table_name;
SELECT COUNT(*) AS AFS_LAB_TABLES FROM dba_tables WHERE owner='AFS_LAB';
SELECT session_id, username, program, status FROM v$session WHERE username='AFS_LAB';
