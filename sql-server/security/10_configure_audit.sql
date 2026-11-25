/*
  AFS-DBA-001
  Purpose: Configure a server audit to a protected local folder and database
           audit specifications for permission/schema changes.
  Safety: Idempotent. Requires sysadmin and a folder writable by the SQL Server
          service account. If the folder is unavailable, the audit creation
          fails; do not claim auditing is enabled until it is verified.
  Prerequisites: C:\AFS\Audit (or overridden AuditRoot) exists; service account
                 has modify permission; SQL Server Audit is supported by the edition.
*/

-- AuditRoot is supplied by sqlcmd -v; a :setvar default would override it.
USE [master];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'AFS_ServerAudit')
BEGIN
    CREATE SERVER AUDIT [AFS_ServerAudit]
    TO FILE
    (
        FILEPATH = N'$(AuditRoot)\',
        MAXSIZE = 100 MB,
        MAX_ROLLOVER_FILES = 10,
        RESERVE_DISK_SPACE = OFF
    )
    WITH
    (
        QUEUE_DELAY = 1000,
        ON_FAILURE = CONTINUE
    );
END
GO

ALTER SERVER AUDIT [AFS_ServerAudit] WITH (STATE = ON);
GO

USE [AFS_CoreBanking];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'AFS_CoreBanking_Audit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [AFS_CoreBanking_Audit]
    FOR SERVER AUDIT [AFS_ServerAudit]
    ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP)
    WITH (STATE = ON);
END
GO

USE [AFS_Payments];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'AFS_Payments_Audit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [AFS_Payments_Audit]
    FOR SERVER AUDIT [AFS_ServerAudit]
    ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP)
    WITH (STATE = ON);
END
GO

USE [AFS_Audit];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = N'AFS_Audit_Audit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION [AFS_Audit_Audit]
    FOR SERVER AUDIT [AFS_ServerAudit]
    ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_PERMISSION_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_CHANGE_GROUP)
    WITH (STATE = ON);
END
GO

PRINT N'Audit configuration attempted. Verify with sys.server_audits and sys.database_audit_specifications.';
GO

SELECT name, is_state_enabled, status_desc, audit_file_path
FROM sys.server_audits
WHERE name = N'AFS_ServerAudit';
GO
