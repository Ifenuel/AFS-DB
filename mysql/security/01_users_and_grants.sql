-- AFS-DBA-001
-- Purpose: MySQL least-privilege exercise (executed 2026-11-25 on MySQL 8.4.9).
-- Evidence: evidence/verify/live/34_mysql_security.txt, 35_mysql_least_privilege.txt
-- Safety: Creates roles/users if missing. Replace the password placeholders in
--         the MySQL client session; never commit a real password.
-- Run as: MySQL administrator on a disposable lab instance.
--
-- Example (do not paste a real password into this file):
--   SET @afs_app_password = '...generated locally...';
--   -- Then use a client-side parameter substitution or a local secret file.

CREATE DATABASE IF NOT EXISTS afs_lab
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

CREATE ROLE IF NOT EXISTS 'afs_readonly';
CREATE ROLE IF NOT EXISTS 'afs_app';

GRANT SELECT ON afs_lab.* TO 'afs_readonly';

CREATE USER IF NOT EXISTS 'afs_readonly'@'localhost'
  IDENTIFIED BY 'REPLACE_WITH_LOCAL_SECRET'
  PASSWORD EXPIRE INTERVAL 180 DAY;

CREATE USER IF NOT EXISTS 'afs_app'@'localhost'
  IDENTIFIED BY 'REPLACE_WITH_LOCAL_SECRET'
  PASSWORD EXPIRE INTERVAL 180 DAY;

GRANT 'afs_readonly' TO 'afs_app'@'localhost';

-- A granted role is inactive until it is enabled. Without this line an
-- application login would be denied on afs_lab every time (verified: the
-- first run of the negative test failed with ERROR 1142 until SET ROLE).
SET DEFAULT ROLE afs_readonly TO 'afs_app'@'localhost';

-- The application must not be able to grant privileges, alter schemas, or read
-- the mysql system database. Verify with SHOW GRANTS and negative tests.
SHOW GRANTS FOR 'afs_app'@'localhost';
SHOW GRANTS FOR 'afs_readonly'@'localhost';
