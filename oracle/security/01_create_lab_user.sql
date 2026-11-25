-- AFS-DBA-001
-- Purpose: Oracle least-privilege lab user exercise (authored, not executed).
-- Run as: a DBA in the FREEPDB1 pluggable database, e.g.
--   sqlplus system@localhost:1521/FREEPDB1
-- The password is accepted interactively and is not stored in this file.

SET ECHO OFF
SET VERIFY OFF
ACCEPT afs_password CHAR PROMPT 'Enter a unique credential for AFS_LAB (hidden): ' HIDE

CREATE USER afs_lab IDENTIFIED BY "&afs_password"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users
  ACCOUNT UNLOCK;

GRANT CREATE SESSION TO afs_lab;
GRANT CREATE TABLE TO afs_lab;
GRANT CREATE VIEW TO afs_lab;
GRANT CREATE PROCEDURE TO afs_lab;
GRANT CREATE SEQUENCE TO afs_lab;

-- Deliberately do not grant DBA, SYSDBA, CREATE ANY TABLE, or SELECT ANY TABLE.
-- Verify with:
--   SELECT * FROM dba_sys_privs WHERE grantee = 'AFS_LAB';
--   SELECT * FROM dba_role_privs WHERE grantee = 'AFS_LAB';

PROMPT AFS_LAB created. Verify privileges and then connect as AFS_LAB.
