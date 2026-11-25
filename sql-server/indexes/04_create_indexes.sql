/*
  AFS-DBA-001
  Purpose: Create indexes justified by known query patterns.
  Safety: Idempotent.
  Note: Indexes are not "free"; review usage and write cost after the workload runs.
*/

USE [AFS_CoreBanking];
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_customer_Customer_Email' AND object_id = OBJECT_ID(N'customer.Customer'))
    CREATE UNIQUE INDEX IX_customer_Customer_Email
        ON customer.Customer (Email)
        WHERE Email IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_Account_CustomerId' AND object_id = OBJECT_ID(N'account.Account'))
    CREATE INDEX IX_account_Account_CustomerId
        ON account.Account (CustomerId)
        INCLUDE (AccountNumber, AccountStatusId, CurrencyCode, Balance);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_Account_Status' AND object_id = OBJECT_ID(N'account.Account'))
    CREATE INDEX IX_account_Account_Status
        ON account.Account (AccountStatusId)
        INCLUDE (CustomerId, CurrencyCode, Balance);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_Transfer_From_CompletedAt' AND object_id = OBJECT_ID(N'account.Transfer'))
    CREATE INDEX IX_account_Transfer_From_CompletedAt
        ON account.Transfer (FromAccountId, CompletedAt)
        INCLUDE (Amount, CurrencyCode, ToAccountId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_Transfer_To_CompletedAt' AND object_id = OBJECT_ID(N'account.Transfer'))
    CREATE INDEX IX_account_Transfer_To_CompletedAt
        ON account.Transfer (ToAccountId, CompletedAt)
        INCLUDE (Amount, CurrencyCode, FromAccountId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_Transfer_CompletedAt' AND object_id = OBJECT_ID(N'account.Transfer'))
    CREATE INDEX IX_account_Transfer_CompletedAt
        ON account.Transfer (CompletedAt)
        INCLUDE (Amount, CurrencyCode, FromAccountId, ToAccountId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_account_AccountLedgerEntry_Account_OccurredAt' AND object_id = OBJECT_ID(N'account.AccountLedgerEntry'))
    CREATE INDEX IX_account_AccountLedgerEntry_Account_OccurredAt
        ON account.AccountLedgerEntry (AccountId, OccurredAt)
        INCLUDE (TransferId, EntryType, Amount, BalanceAfter, CurrencyCode);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_AuditEvent_Entity_CreatedAt' AND object_id = OBJECT_ID(N'audit.AuditEvent'))
    CREATE INDEX IX_audit_AuditEvent_Entity_CreatedAt
        ON audit.AuditEvent (EntityType, EntityId, CreatedAt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_AuditEvent_EventType_CreatedAt' AND object_id = OBJECT_ID(N'audit.AuditEvent'))
    CREATE INDEX IX_audit_AuditEvent_EventType_CreatedAt
        ON audit.AuditEvent (EventType, CreatedAt);
GO

USE [AFS_Payments];
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_payment_Payment_DebitAccount_CreatedAt' AND object_id = OBJECT_ID(N'payment.Payment'))
    CREATE INDEX IX_payment_Payment_DebitAccount_CreatedAt
        ON payment.Payment (DebitAccountId, CreatedAt)
        INCLUDE (Amount, CurrencyCode, PaymentStatusId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_payment_Payment_Status_CreatedAt' AND object_id = OBJECT_ID(N'payment.Payment'))
    CREATE INDEX IX_payment_Payment_Status_CreatedAt
        ON payment.Payment (PaymentStatusId, CreatedAt)
        INCLUDE (DebitAccountId, Amount, CurrencyCode);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_payment_PaymentEvent_Payment' AND object_id = OBJECT_ID(N'payment.PaymentEvent'))
    CREATE INDEX IX_payment_PaymentEvent_Payment
        ON payment.PaymentEvent (PaymentId, CreatedAt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_settlement_SettlementItem_Batch' AND object_id = OBJECT_ID(N'settlement.SettlementItem'))
    CREATE INDEX IX_settlement_SettlementItem_Batch
        ON settlement.SettlementItem (SettlementBatchId, Status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_AuditEvent_Entity_CreatedAt' AND object_id = OBJECT_ID(N'audit.AuditEvent'))
    CREATE INDEX IX_audit_AuditEvent_Entity_CreatedAt
        ON audit.AuditEvent (EntityType, EntityId, CreatedAt);
GO

USE [AFS_CustomerService];
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_support_SupportCase_Customer_OpenedAt' AND object_id = OBJECT_ID(N'support.SupportCase'))
    CREATE INDEX IX_support_SupportCase_Customer_OpenedAt
        ON support.SupportCase (CustomerId, OpenedAt)
        INCLUDE (Status, Priority, CaseCategoryId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_support_SupportCase_Status_Priority' AND object_id = OBJECT_ID(N'support.SupportCase'))
    CREATE INDEX IX_support_SupportCase_Status_Priority
        ON support.SupportCase (Status, Priority, OpenedAt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_support_CaseNote_Case' AND object_id = OBJECT_ID(N'support.CaseNote'))
    CREATE INDEX IX_support_CaseNote_Case
        ON support.CaseNote (CaseId, CreatedAt);
GO

USE [AFS_Audit];
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_AuditRecord_EventTime' AND object_id = OBJECT_ID(N'audit.AuditRecord'))
    CREATE INDEX IX_audit_AuditRecord_EventTime
        ON audit.AuditRecord (EventTime);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_security_SecurityEvent_EventTime' AND object_id = OBJECT_ID(N'security.SecurityEvent'))
    CREATE INDEX IX_security_SecurityEvent_EventTime
        ON security.SecurityEvent (EventTime, Success, EventType);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_operational_BackupHistory_Database_CompletedAt' AND object_id = OBJECT_ID(N'operational.BackupHistory'))
    CREATE INDEX IX_operational_BackupHistory_Database_CompletedAt
        ON operational.BackupHistory (DatabaseName, CompletedAt DESC);
GO

USE [AFS_Fraud];
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fraud_FraudAlert_Status_CreatedAt' AND object_id = OBJECT_ID(N'fraud.FraudAlert'))
    CREATE INDEX IX_fraud_FraudAlert_Status_CreatedAt
        ON fraud.FraudAlert (Status, CreatedAt);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_fraud_FraudAlert_Customer_CreatedAt' AND object_id = OBJECT_ID(N'fraud.FraudAlert'))
    CREATE INDEX IX_fraud_FraudAlert_Customer_CreatedAt
        ON fraud.FraudAlert (CustomerId, CreatedAt);
GO

PRINT N'Indexes created (or already existed).';
GO
