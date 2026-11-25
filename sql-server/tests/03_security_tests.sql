/*
  AFS-DBA-001
  Purpose: Positive and negative permission tests using EXECUTE AS USER.
  Safety: Read-only or zero-row statements; no financial data is changed.
  Prerequisites: Security scripts executed; users/roles exist.
  Run as: AFS_DBA (sysadmin is required to impersonate users).
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
GO

CREATE TABLE #Results
(
    TestId VARCHAR(20) NOT NULL,
    TestName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(300) NOT NULL,
    Actual NVARCHAR(300) NOT NULL,
    Status VARCHAR(10) NOT NULL
);

DECLARE @Can BIT;
DECLARE @Outcome VARCHAR(10);

-- T-SEC-001: application can execute the transfer procedure.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SET @Can = HAS_PERMS_BY_NAME(N'account.usp_ExecuteTransfer', N'OBJECT', N'EXECUTE');
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-001', N'App can execute transfer procedure', N'1',
         CONVERT(NVARCHAR(10), @Can), CASE WHEN @Can = 1 THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-001', N'App can execute transfer procedure', N'1',
         CONCAT(N'Error ', ERROR_NUMBER()), 'FAIL');
END CATCH;

-- T-SEC-002: application cannot select the financial base table directly.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SELECT TOP (1) * FROM account.Account;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-002', N'App cannot select account.Account', N'Permission denied',
         N'Query succeeded', 'FAIL');
END TRY
BEGIN CATCH
    SET @Outcome = 'DENIED';
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-002', N'App cannot select account.Account', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

-- T-SEC-003: application cannot update balances directly.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    UPDATE account.Account SET Balance = Balance WHERE 1 = 0;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-003', N'App cannot update account.Account', N'Permission denied',
         N'Update succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-003', N'App cannot update account.Account', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

-- T-SEC-004: application cannot read audit rows directly.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SELECT TOP (1) * FROM audit.AuditEvent;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-004', N'App cannot select audit.AuditEvent', N'Permission denied',
         N'Query succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-004', N'App cannot select audit.AuditEvent', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

-- T-SEC-005: application can read the masked customer profile view.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SELECT TOP (1) CustomerId, EmailMasked FROM customer.vw_CustomerProfile;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-005', N'App can select masked customer profile', N'Success',
         N'Success', 'PASS');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-005', N'App can select masked customer profile', N'Success',
         CONCAT(N'Error ', ERROR_NUMBER()), 'FAIL');
END CATCH;

-- T-SEC-006: developer is read-only on financial base tables.
BEGIN TRY
    EXECUTE AS USER = N'AFS_Developer';
    UPDATE account.Account SET Balance = Balance WHERE 1 = 0;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-006', N'Developer cannot update account.Account', N'Permission denied',
         N'Update succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-006', N'Developer cannot update account.Account', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

USE [AFS_Payments];
GO

DECLARE @Can BIT;

-- T-SEC-007: application can execute payment creation.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SET @Can = HAS_PERMS_BY_NAME(N'payment.usp_CreatePayment', N'OBJECT', N'EXECUTE');
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-007', N'App can execute payment procedure', N'1',
         CONVERT(NVARCHAR(10), @Can), CASE WHEN @Can = 1 THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-007', N'App can execute payment procedure', N'1',
         CONCAT(N'Error ', ERROR_NUMBER()), 'FAIL');
END CATCH;

-- T-SEC-008: application cannot read the payment base table directly.
BEGIN TRY
    EXECUTE AS USER = N'AFS_App';
    SELECT TOP (1) * FROM payment.Payment;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-008', N'App cannot select payment.Payment', N'Permission denied',
         N'Query succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-008', N'App cannot select payment.Payment', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

USE [AFS_Reporting];
GO

-- T-SEC-009: reporting can read its reporting view and cannot reach Core tables.
BEGIN TRY
    EXECUTE AS USER = N'AFS_Reporting';
    SELECT TOP (1) SummaryDate, CurrencyCode FROM reporting.vw_TransferVolume;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-009', N'Reporting can select reporting view', N'Success',
         N'Success', 'PASS');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-009', N'Reporting can select reporting view', N'Success',
         CONCAT(N'Error ', ERROR_NUMBER()), 'FAIL');
END CATCH;

BEGIN TRY
    EXECUTE AS USER = N'AFS_Reporting';
    SELECT TOP (1) * FROM AFS_CoreBanking.account.Account;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-010', N'Reporting cannot select Core account table', N'Permission denied',
         N'Query succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-010', N'Reporting cannot select Core account table', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

USE [AFS_Audit];
GO

-- T-SEC-011: auditor can read the audit record.
BEGIN TRY
    EXECUTE AS USER = N'AFS_Auditor';
    SELECT TOP (1) AuditRecordId, EventType FROM audit.AuditRecord;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-011', N'Auditor can select audit records', N'Success',
         N'Success', 'PASS');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-011', N'Auditor can select audit records', N'Success',
         CONCAT(N'Error ', ERROR_NUMBER()), 'FAIL');
END CATCH;

-- T-SEC-012: auditor cannot modify audit records.
BEGIN TRY
    EXECUTE AS USER = N'AFS_Auditor';
    UPDATE audit.AuditRecord SET EventType = EventType WHERE 1 = 0;
    REVERT;
    INSERT #Results VALUES
        ('T-SEC-012', N'Auditor cannot update audit records', N'Permission denied',
         N'Update succeeded', 'FAIL');
END TRY
BEGIN CATCH
    IF USER_NAME() <> N'dbo' REVERT;
    INSERT #Results VALUES
        ('T-SEC-012', N'Auditor cannot update audit records', N'Permission denied',
         CONCAT(N'Denied: ', ERROR_NUMBER()), 'PASS');
END CATCH;

SELECT TestId, TestName, Expected, Actual, Status FROM #Results ORDER BY TestId;
SELECT COUNT(*) AS TotalTests,
       SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS Passed,
       SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS Failed
FROM #Results;

IF EXISTS (SELECT 1 FROM #Results WHERE Status = 'FAIL')
    THROW 59950, N'One or more security tests failed.', 1;

PRINT N'ALL SECURITY TESTS PASSED.';
GO
