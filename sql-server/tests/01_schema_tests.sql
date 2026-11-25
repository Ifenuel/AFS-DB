/*
  AFS-DBA-001
  Purpose: Verify that the expected databases, schemas, tables, procedures and
           seed rows exist after deployment.
  Safety: Read-only. Fails fast with THROW if an expected object is missing.
  Run as: AFS_DBA.
*/

SET NOCOUNT ON;

IF DB_ID(N'AFS_CoreBanking') IS NULL THROW 59001, N'AFS_CoreBanking is missing.', 1;
IF DB_ID(N'AFS_Payments') IS NULL THROW 59001, N'AFS_Payments is missing.', 1;
IF DB_ID(N'AFS_CustomerService') IS NULL THROW 59001, N'AFS_CustomerService is missing.', 1;
IF DB_ID(N'AFS_Audit') IS NULL THROW 59001, N'AFS_Audit is missing.', 1;
IF DB_ID(N'AFS_Reporting') IS NULL THROW 59001, N'AFS_Reporting is missing.', 1;
IF DB_ID(N'AFS_Fraud') IS NULL THROW 59001, N'AFS_Fraud is missing.', 1;

USE [AFS_CoreBanking];
GO
IF OBJECT_ID(N'customer.Customer', N'U') IS NULL THROW 59002, N'customer.Customer is missing.', 1;
IF OBJECT_ID(N'customer.CustomerContact', N'U') IS NULL THROW 59002, N'customer.CustomerContact is missing.', 1;
IF OBJECT_ID(N'customer.CustomerAddress', N'U') IS NULL THROW 59002, N'customer.CustomerAddress is missing.', 1;
IF OBJECT_ID(N'account.Account', N'U') IS NULL THROW 59002, N'account.Account is missing.', 1;
IF OBJECT_ID(N'account.Transfer', N'U') IS NULL THROW 59002, N'account.Transfer is missing.', 1;
IF OBJECT_ID(N'account.TransferEvent', N'U') IS NULL THROW 59002, N'account.TransferEvent is missing.', 1;
IF OBJECT_ID(N'account.AccountLedgerEntry', N'U') IS NULL THROW 59002, N'account.AccountLedgerEntry is missing.', 1;
IF OBJECT_ID(N'audit.AuditEvent', N'U') IS NULL THROW 59002, N'audit.AuditEvent is missing.', 1;
IF OBJECT_ID(N'account.usp_ExecuteTransfer', N'P') IS NULL THROW 59003, N'account.usp_ExecuteTransfer is missing.', 1;
IF OBJECT_ID(N'account.usp_ReconcileBalances', N'P') IS NULL THROW 59003, N'account.usp_ReconcileBalances is missing.', 1;
IF OBJECT_ID(N'account.usp_ReconcileTransfers', N'P') IS NULL THROW 59003, N'account.usp_ReconcileTransfers is missing.', 1;
IF OBJECT_ID(N'account.ufn_AccountStatement', N'IF') IS NULL THROW 59004, N'account.ufn_AccountStatement is missing.', 1;
IF OBJECT_ID(N'customer.vw_CustomerProfile', N'V') IS NULL THROW 59005, N'customer.vw_CustomerProfile is missing.', 1;
IF OBJECT_ID(N'account.vw_AccountSummary', N'V') IS NULL THROW 59005, N'account.vw_AccountSummary is missing.', 1;
IF COL_LENGTH(N'account.AccountLedgerEntry', N'EntryType') IS NULL THROW 59006, N'Ledger EntryType column is missing.', 1;
IF COL_LENGTH(N'account.Account', N'OpeningBalance') IS NULL THROW 59006, N'Account OpeningBalance column is missing.', 1;
IF NOT EXISTS (SELECT 1 FROM reference.AccountStatus WHERE StatusCode = 'ACTIVE')
    THROW 59007, N'Reference account statuses are not seeded.', 1;
IF NOT EXISTS (SELECT 1 FROM reference.Currency WHERE CurrencyCode = 'USD')
    THROW 59007, N'Reference currencies are not seeded.', 1;
PRINT N'AFS_CoreBanking schema checks passed.';
GO

USE [AFS_Payments];
GO
IF OBJECT_ID(N'payment.Payment', N'U') IS NULL THROW 59010, N'payment.Payment is missing.', 1;
IF OBJECT_ID(N'payment.PaymentEvent', N'U') IS NULL THROW 59010, N'payment.PaymentEvent is missing.', 1;
IF OBJECT_ID(N'settlement.SettlementBatch', N'U') IS NULL THROW 59010, N'settlement.SettlementBatch is missing.', 1;
IF OBJECT_ID(N'transfer.TransferProjection', N'V') IS NULL THROW 59011, N'transfer.TransferProjection is missing.', 1;
IF OBJECT_ID(N'payment.usp_CreatePayment', N'P') IS NULL THROW 59012, N'payment.usp_CreatePayment is missing.', 1;
IF OBJECT_ID(N'payment.usp_ReconcilePayments', N'P') IS NULL THROW 59012, N'payment.usp_ReconcilePayments is missing.', 1;
IF NOT EXISTS (SELECT 1 FROM payment.PaymentStatus WHERE StatusCode = 'PENDING')
    THROW 59013, N'Payment statuses are not seeded.', 1;
PRINT N'AFS_Payments schema checks passed.';
GO

USE [AFS_CustomerService];
GO
IF OBJECT_ID(N'support.SupportCase', N'U') IS NULL THROW 59020, N'support.SupportCase is missing.', 1;
IF OBJECT_ID(N'support.CaseNote', N'U') IS NULL THROW 59020, N'support.CaseNote is missing.', 1;
IF OBJECT_ID(N'service_request.ServiceRequest', N'U') IS NULL THROW 59020, N'service_request.ServiceRequest is missing.', 1;
IF OBJECT_ID(N'escalation.Escalation', N'U') IS NULL THROW 59020, N'escalation.Escalation is missing.', 1;
PRINT N'AFS_CustomerService schema checks passed.';
GO

USE [AFS_Audit];
GO
IF OBJECT_ID(N'security.SecurityEvent', N'U') IS NULL THROW 59030, N'security.SecurityEvent is missing.', 1;
IF OBJECT_ID(N'audit.AuditRecord', N'U') IS NULL THROW 59030, N'audit.AuditRecord is missing.', 1;
IF OBJECT_ID(N'operational.BackupHistory', N'U') IS NULL THROW 59030, N'operational.BackupHistory is missing.', 1;
PRINT N'AFS_Audit schema checks passed.';
GO

USE [AFS_Reporting];
GO
IF OBJECT_ID(N'staging.StgTransaction', N'U') IS NULL THROW 59040, N'staging.StgTransaction is missing.', 1;
IF OBJECT_ID(N'reporting.DailyAccountSummary', N'U') IS NULL THROW 59040, N'reporting.DailyAccountSummary is missing.', 1;
IF OBJECT_ID(N'warehouse.FactTransaction', N'U') IS NULL THROW 59040, N'warehouse.FactTransaction is missing.', 1;
PRINT N'AFS_Reporting schema checks passed.';
GO

USE [AFS_Fraud];
GO
IF OBJECT_ID(N'fraud.FraudRule', N'U') IS NULL THROW 59050, N'fraud.FraudRule is missing.', 1;
IF OBJECT_ID(N'fraud.FraudAlert', N'U') IS NULL THROW 59050, N'fraud.FraudAlert is missing.', 1;
IF OBJECT_ID(N'fraud.FraudCase', N'U') IS NULL THROW 59050, N'fraud.FraudCase is missing.', 1;
PRINT N'AFS_Fraud schema checks passed.';
GO

PRINT N'ALL SCHEMA TESTS PASSED.';
GO
