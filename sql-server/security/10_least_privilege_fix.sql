/*
  AFS-DBA-001
  P-04 fix: least privilege plus an in-database audit trail.

  The application no longer touches tables directly. It may execute the payment
  procedure; every ledger write made through it is captured with the calling
  principal, so privileged activity can be reconstructed after the fact.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE AFS_Payments;
GO

REVOKE CONTROL ON SCHEMA::paylab FROM paylab_app;
GO

/* application: execute the API, read its own reference data, no direct DML */
GRANT EXECUTE ON OBJECT::paylab.usp_Submit_Safe TO paylab_app;
GRANT EXECUTE ON OBJECT::paylab.usp_TracePayment TO paylab_app;
GRANT SELECT ON OBJECT::paylab.PaymentIntent TO paylab_app;
GRANT SELECT ON OBJECT::paylab.LedgerEntry TO paylab_app;
DENY UPDATE, DELETE ON OBJECT::paylab.LedgerEntry TO paylab_app;
DENY UPDATE, DELETE, INSERT ON OBJECT::paylab.SecurityLog TO paylab_app;
DENY ALTER ON SCHEMA::paylab TO paylab_app;
GO

/* auditor: read everything in the lab, write nothing */
GRANT SELECT ON SCHEMA::paylab TO paylab_auditor;
DENY INSERT, UPDATE, DELETE ON SCHEMA::paylab TO paylab_auditor;
GO

CREATE OR ALTER TRIGGER paylab.trg_LedgerAudit
ON paylab.LedgerEntry
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @action varchar(10) =
        CASE WHEN EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted) THEN 'UPDATE'
             WHEN EXISTS (SELECT 1 FROM inserted) THEN 'INSERT'
             ELSE 'DELETE' END;
    DECLARE @rows int = (SELECT COUNT(*) FROM inserted) + (SELECT COUNT(*) FROM deleted);

    INSERT INTO paylab.SecurityLog (PrincipalName, Action, ObjectName, RowsAffected, Detail)
    VALUES (USER_NAME(), @action, 'paylab.LedgerEntry', @rows,
            CONCAT('session=', SESSION_USER, ' rows=', @rows));
END
GO

SELECT p.name AS principal, dp.permission_name, dp.state_desc, dp.class_desc
FROM sys.database_permissions dp
JOIN sys.database_principals p ON p.principal_id = dp.grantee_principal_id
WHERE p.name IN ('paylab_app','paylab_auditor')
ORDER BY p.name, dp.permission_name;
GO
PRINT 'least privilege and audit trigger applied';
GO
