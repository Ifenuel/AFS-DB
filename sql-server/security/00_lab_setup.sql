/*
  AFS-DBA-001
  P-04 privileged access and audit evidence.

  Baseline deliberately over-privileges an application principal: CONTROL on the
  paylab schema, which is effectively ownership of every lab object. There is no
  audit trigger yet, so a privileged write leaves no in-database evidence.

  Users are created WITHOUT LOGIN and exercised with EXECUTE AS USER, so no
  credential exists and no external system is touched.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE AFS_Payments;
GO

/* Return to the unhardened baseline: no audit trigger, no residual DENY rows. */
IF OBJECT_ID('paylab.trg_LedgerAudit') IS NOT NULL DROP TRIGGER paylab.trg_LedgerAudit;
GO
IF USER_ID('paylab_auditor') IS NOT NULL DROP USER paylab_auditor;
IF USER_ID('paylab_app') IS NOT NULL DROP USER paylab_app;
GO
CREATE USER paylab_app WITHOUT LOGIN;
CREATE USER paylab_auditor WITHOUT LOGIN;
GO

IF OBJECT_ID('paylab.SecurityLog') IS NULL
CREATE TABLE paylab.SecurityLog
(
    AuditId       bigint IDENTITY(1,1) NOT NULL,
    EventTime     datetime2(7)         NOT NULL CONSTRAINT DF_paylab_SecurityLog_At DEFAULT (SYSUTCDATETIME()),
    PrincipalName sysname              NOT NULL,
    Action        varchar(10)          NOT NULL,
    ObjectName    varchar(80)          NOT NULL,
    RowsAffected  int                  NOT NULL,
    Detail        nvarchar(200)        NULL,
    CONSTRAINT PK_paylab_SecurityLog PRIMARY KEY (AuditId)
);
GO

/* baseline: the application can do anything in the lab schema */
GRANT CONTROL ON SCHEMA::paylab TO paylab_app;
GRANT SELECT ON SCHEMA::paylab TO paylab_auditor;
GO

SELECT p.name AS principal, dp.permission_name, dp.state_desc, dp.class_desc
FROM sys.database_permissions dp
JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
WHERE p.name IN ('paylab_app','paylab_auditor')
ORDER BY p.name, dp.permission_name;
GO
PRINT 'security lab baseline ready';
GO
