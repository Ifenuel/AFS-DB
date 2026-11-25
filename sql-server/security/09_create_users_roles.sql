/*
  AFS-DBA-001
  Purpose: Map logins to database users and enforce least privilege.
  Safety: Idempotent (existence checks and repeatable grants).
  Prerequisites: Logins from 08_create_logins.sql; all databases/tables/views/procs.
  Run as: AFS_DBA.
*/

USE [AFS_CoreBanking];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_App') IS NULL CREATE USER [AFS_App] FOR LOGIN [AFS_App];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops') IS NULL CREATE USER [AFS_Ops] FOR LOGIN [AFS_Ops];
GO

IF DATABASE_PRINCIPAL_ID(N'AFS_App_Core') IS NULL CREATE ROLE [AFS_App_Core] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer_Core') IS NULL CREATE ROLE [AFS_Developer_Core] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops_Core') IS NULL CREATE ROLE [AFS_Ops_Core] AUTHORIZATION [dbo];
GO

IF IS_ROLEMEMBER(N'AFS_App_Core', N'AFS_App') = 0 ALTER ROLE [AFS_App_Core] ADD MEMBER [AFS_App];
IF IS_ROLEMEMBER(N'AFS_Developer_Core', N'AFS_Developer') = 0 ALTER ROLE [AFS_Developer_Core] ADD MEMBER [AFS_Developer];
IF IS_ROLEMEMBER(N'AFS_Ops_Core', N'AFS_Ops') = 0 ALTER ROLE [AFS_Ops_Core] ADD MEMBER [AFS_Ops];
GO

-- Application: execute approved procedures and read masked projections only.
GRANT EXECUTE ON OBJECT::account.usp_ExecuteTransfer TO [AFS_App_Core];
GRANT EXECUTE ON OBJECT::account.usp_GetAccountSummary TO [AFS_App_Core];
GRANT EXECUTE ON OBJECT::account.usp_GetTransfer TO [AFS_App_Core];
GRANT SELECT ON OBJECT::customer.vw_CustomerProfile TO [AFS_App_Core];
GRANT SELECT ON OBJECT::account.vw_AccountSummary TO [AFS_App_Core];
GRANT SELECT ON OBJECT::account.vw_TransferProjection TO [AFS_App_Core];
GRANT SELECT ON OBJECT::account.vw_TransferEventProjection TO [AFS_App_Core];
GRANT SELECT ON SCHEMA::reference TO [AFS_App_Core];
GO

-- Direct financial-table DML is explicitly denied even if a future role
-- membership accidentally grants it. Application writes go through procedures.
DENY INSERT, UPDATE, DELETE ON OBJECT::account.Account TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::account.Transfer TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::account.TransferEvent TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::account.AccountLedgerEntry TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::customer.Customer TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::customer.CustomerContact TO [AFS_App_Core];
DENY INSERT, UPDATE, DELETE ON OBJECT::customer.CustomerAddress TO [AFS_App_Core];
-- No grant on audit.AuditEvent is intentional: the app writes audit only through
-- the owning procedures. Do not add an explicit DENY here, because ownership
-- chaining is what lets the procedure write the audit row.
GO

-- Developer: read-only in the operational lab databases. Schema changes go
-- through versioned migrations under DBA control, not ad-hoc developer DML.
GRANT EXECUTE ON OBJECT::account.usp_GetAccountSummary TO [AFS_Developer_Core];
GRANT EXECUTE ON OBJECT::account.usp_GetTransfer TO [AFS_Developer_Core];
GRANT EXECUTE ON OBJECT::account.usp_ReconcileBalances TO [AFS_Developer_Core];
GRANT EXECUTE ON OBJECT::account.usp_ReconcileTransfers TO [AFS_Developer_Core];
GRANT SELECT ON OBJECT::customer.vw_CustomerProfile TO [AFS_Developer_Core];
GRANT SELECT ON OBJECT::account.vw_AccountSummary TO [AFS_Developer_Core];
GRANT SELECT ON OBJECT::account.vw_TransferProjection TO [AFS_Developer_Core];
GRANT SELECT ON OBJECT::account.vw_TransferEventProjection TO [AFS_Developer_Core];
GRANT SELECT ON SCHEMA::reference TO [AFS_Developer_Core];
GO

-- Operations: health checks and reconciliation, not financial data changes.
GRANT EXECUTE ON OBJECT::account.usp_GetAccountSummary TO [AFS_Ops_Core];
GRANT EXECUTE ON OBJECT::account.usp_GetTransfer TO [AFS_Ops_Core];
GRANT EXECUTE ON OBJECT::account.usp_ReconcileBalances TO [AFS_Ops_Core];
GRANT EXECUTE ON OBJECT::account.usp_ReconcileTransfers TO [AFS_Ops_Core];
GRANT SELECT ON OBJECT::account.vw_AccountSummary TO [AFS_Ops_Core];
GO

PRINT N'AFS_CoreBanking users/roles configured.';
GO

USE [AFS_Payments];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_App') IS NULL CREATE USER [AFS_App] FOR LOGIN [AFS_App];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops') IS NULL CREATE USER [AFS_Ops] FOR LOGIN [AFS_Ops];
GO

IF DATABASE_PRINCIPAL_ID(N'AFS_App_Payments') IS NULL CREATE ROLE [AFS_App_Payments] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer_Payments') IS NULL CREATE ROLE [AFS_Developer_Payments] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops_Payments') IS NULL CREATE ROLE [AFS_Ops_Payments] AUTHORIZATION [dbo];
GO

IF IS_ROLEMEMBER(N'AFS_App_Payments', N'AFS_App') = 0 ALTER ROLE [AFS_App_Payments] ADD MEMBER [AFS_App];
IF IS_ROLEMEMBER(N'AFS_Developer_Payments', N'AFS_Developer') = 0 ALTER ROLE [AFS_Developer_Payments] ADD MEMBER [AFS_Developer];
IF IS_ROLEMEMBER(N'AFS_Ops_Payments', N'AFS_Ops') = 0 ALTER ROLE [AFS_Ops_Payments] ADD MEMBER [AFS_Ops];
GO

GRANT EXECUTE ON OBJECT::payment.usp_CreatePayment TO [AFS_App_Payments];
GRANT EXECUTE ON OBJECT::payment.usp_GetPayment TO [AFS_App_Payments];
GRANT SELECT ON OBJECT::transfer.TransferProjection TO [AFS_App_Payments];
GRANT SELECT ON OBJECT::transfer.TransferEventProjection TO [AFS_App_Payments];
GRANT SELECT ON OBJECT::payment.vw_PaymentSummary TO [AFS_App_Payments];
GRANT SELECT ON OBJECT::payment.PaymentMethod TO [AFS_App_Payments];
GRANT SELECT ON OBJECT::payment.PaymentStatus TO [AFS_App_Payments];
GO

DENY INSERT, UPDATE, DELETE ON OBJECT::payment.Payment TO [AFS_App_Payments];
DENY INSERT, UPDATE, DELETE ON OBJECT::payment.PaymentEvent TO [AFS_App_Payments];
DENY INSERT, UPDATE, DELETE ON OBJECT::settlement.SettlementBatch TO [AFS_App_Payments];
DENY INSERT, UPDATE, DELETE ON OBJECT::settlement.SettlementItem TO [AFS_App_Payments];
-- Audit writes occur through the owning procedures; no direct grant is given.
GO

GRANT EXECUTE ON OBJECT::payment.usp_GetPayment TO [AFS_Developer_Payments];
GRANT EXECUTE ON OBJECT::payment.usp_ReconcilePayments TO [AFS_Developer_Payments];
GRANT SELECT ON OBJECT::transfer.TransferProjection TO [AFS_Developer_Payments];
GRANT SELECT ON OBJECT::transfer.TransferEventProjection TO [AFS_Developer_Payments];
GRANT SELECT ON OBJECT::payment.vw_PaymentSummary TO [AFS_Developer_Payments];
GRANT SELECT ON OBJECT::payment.PaymentMethod TO [AFS_Developer_Payments];
GRANT SELECT ON OBJECT::payment.PaymentStatus TO [AFS_Developer_Payments];
GO

GRANT EXECUTE ON OBJECT::payment.usp_GetPayment TO [AFS_Ops_Payments];
GRANT EXECUTE ON OBJECT::payment.usp_ReconcilePayments TO [AFS_Ops_Payments];
GRANT SELECT ON OBJECT::transfer.TransferProjection TO [AFS_Ops_Payments];
GRANT SELECT ON OBJECT::payment.vw_PaymentSummary TO [AFS_Ops_Payments];
GO

PRINT N'AFS_Payments users/roles configured.';
GO

USE [AFS_CustomerService];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_App') IS NULL CREATE USER [AFS_App] FOR LOGIN [AFS_App];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
GO

IF DATABASE_PRINCIPAL_ID(N'AFS_App_CustomerService') IS NULL CREATE ROLE [AFS_App_CustomerService] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer_CustomerService') IS NULL CREATE ROLE [AFS_Developer_CustomerService] AUTHORIZATION [dbo];
GO

IF IS_ROLEMEMBER(N'AFS_App_CustomerService', N'AFS_App') = 0 ALTER ROLE [AFS_App_CustomerService] ADD MEMBER [AFS_App];
IF IS_ROLEMEMBER(N'AFS_Developer_CustomerService', N'AFS_Developer') = 0 ALTER ROLE [AFS_Developer_CustomerService] ADD MEMBER [AFS_Developer];
GO

GRANT SELECT ON SCHEMA::support TO [AFS_App_CustomerService];
GRANT SELECT ON SCHEMA::service_request TO [AFS_App_CustomerService];
GRANT SELECT ON SCHEMA::escalation TO [AFS_App_CustomerService];
GRANT SELECT ON SCHEMA::support TO [AFS_Developer_CustomerService];
GRANT SELECT ON SCHEMA::service_request TO [AFS_Developer_CustomerService];
GRANT SELECT ON SCHEMA::escalation TO [AFS_Developer_CustomerService];
GO

DENY INSERT, UPDATE, DELETE ON SCHEMA::support TO [AFS_App_CustomerService];
DENY INSERT, UPDATE, DELETE ON SCHEMA::service_request TO [AFS_App_CustomerService];
DENY INSERT, UPDATE, DELETE ON SCHEMA::escalation TO [AFS_App_CustomerService];
GO

PRINT N'AFS_CustomerService users/roles configured.';
GO

USE [AFS_Reporting];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_Reporting') IS NULL CREATE USER [AFS_Reporting] FOR LOGIN [AFS_Reporting];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
GO

IF DATABASE_PRINCIPAL_ID(N'AFS_Reporting_Role') IS NULL CREATE ROLE [AFS_Reporting_Role] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer_Reporting') IS NULL CREATE ROLE [AFS_Developer_Reporting] AUTHORIZATION [dbo];
GO

IF IS_ROLEMEMBER(N'AFS_Reporting_Role', N'AFS_Reporting') = 0 ALTER ROLE [AFS_Reporting_Role] ADD MEMBER [AFS_Reporting];
IF IS_ROLEMEMBER(N'AFS_Developer_Reporting', N'AFS_Developer') = 0 ALTER ROLE [AFS_Developer_Reporting] ADD MEMBER [AFS_Developer];
GO

GRANT SELECT ON SCHEMA::reporting TO [AFS_Reporting_Role];
GRANT SELECT ON SCHEMA::reporting TO [AFS_Developer_Reporting];
GO

PRINT N'AFS_Reporting users/roles configured.';
GO

USE [AFS_Audit];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_Auditor') IS NULL CREATE USER [AFS_Auditor] FOR LOGIN [AFS_Auditor];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops') IS NULL CREATE USER [AFS_Ops] FOR LOGIN [AFS_Ops];
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
GO

IF DATABASE_PRINCIPAL_ID(N'AFS_Auditor_Role') IS NULL CREATE ROLE [AFS_Auditor_Role] AUTHORIZATION [dbo];
IF DATABASE_PRINCIPAL_ID(N'AFS_Ops_Audit') IS NULL CREATE ROLE [AFS_Ops_Audit] AUTHORIZATION [dbo];
GO

IF IS_ROLEMEMBER(N'AFS_Auditor_Role', N'AFS_Auditor') = 0 ALTER ROLE [AFS_Auditor_Role] ADD MEMBER [AFS_Auditor];
IF IS_ROLEMEMBER(N'AFS_Ops_Audit', N'AFS_Ops') = 0 ALTER ROLE [AFS_Ops_Audit] ADD MEMBER [AFS_Ops];
GO

GRANT SELECT ON SCHEMA::audit TO [AFS_Auditor_Role];
GRANT SELECT ON SCHEMA::security TO [AFS_Auditor_Role];
GRANT SELECT ON SCHEMA::administration TO [AFS_Auditor_Role];
GRANT SELECT ON SCHEMA::operational TO [AFS_Auditor_Role];
GRANT SELECT ON SCHEMA::operational TO [AFS_Ops_Audit];
GO

DENY INSERT, UPDATE, DELETE ON SCHEMA::audit TO [AFS_Auditor_Role];
DENY INSERT, UPDATE, DELETE ON SCHEMA::security TO [AFS_Auditor_Role];
DENY INSERT, UPDATE, DELETE ON SCHEMA::administration TO [AFS_Auditor_Role];
GO

PRINT N'AFS_Audit users/roles configured.';
GO

USE [AFS_Fraud];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer') IS NULL CREATE USER [AFS_Developer] FOR LOGIN [AFS_Developer];
GO
IF DATABASE_PRINCIPAL_ID(N'AFS_Developer_Fraud') IS NULL CREATE ROLE [AFS_Developer_Fraud] AUTHORIZATION [dbo];
GO
IF IS_ROLEMEMBER(N'AFS_Developer_Fraud', N'AFS_Developer') = 0 ALTER ROLE [AFS_Developer_Fraud] ADD MEMBER [AFS_Developer];
GO
GRANT SELECT ON SCHEMA::fraud TO [AFS_Developer_Fraud];
GO

PRINT N'AFS_Fraud users/roles configured.';
GO
