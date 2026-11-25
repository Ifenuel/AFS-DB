/*
  AFS-DBA-001
  Purpose: Create AFS_Payments tables and constraints.
  Safety: Idempotent at table level. Existing tables are not altered.
  Prerequisites: AFS_Payments and schemas; Core tables for the transfer views.
  Run as: AFS_DBA.
*/

USE [AFS_Payments];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'payment.PaymentStatus', N'U') IS NULL
BEGIN
    CREATE TABLE payment.PaymentStatus
    (
        PaymentStatusId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_payment_PaymentStatus PRIMARY KEY,
        StatusCode      VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_payment_PaymentStatus_StatusCode UNIQUE,
        StatusName      NVARCHAR(100) NOT NULL,
        IsTerminal      BIT           NOT NULL
            CONSTRAINT DF_payment_PaymentStatus_IsTerminal DEFAULT (0)
    );
END
GO

IF OBJECT_ID(N'payment.PaymentMethod', N'U') IS NULL
BEGIN
    CREATE TABLE payment.PaymentMethod
    (
        PaymentMethodId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_payment_PaymentMethod PRIMARY KEY,
        MethodCode      VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_payment_PaymentMethod_MethodCode UNIQUE,
        MethodName      NVARCHAR(100) NOT NULL,
        IsActive        BIT           NOT NULL
            CONSTRAINT DF_payment_PaymentMethod_IsActive DEFAULT (1)
    );
END
GO

IF OBJECT_ID(N'payment.Payment', N'U') IS NULL
BEGIN
    CREATE TABLE payment.Payment
    (
        PaymentId                BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_payment_Payment PRIMARY KEY,
        PaymentReference         VARCHAR(24)   NOT NULL
            CONSTRAINT UQ_payment_Payment_PaymentReference UNIQUE,
        RequestId                UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT UQ_payment_Payment_RequestId UNIQUE,
        DebitAccountId           BIGINT        NOT NULL,
        BeneficiaryAccountId     BIGINT        NOT NULL,
        BeneficiaryName          NVARCHAR(200) NOT NULL,
        BeneficiaryAccountNumber NVARCHAR(34)  NOT NULL,
        Amount                   DECIMAL(19,4) NOT NULL,
        CurrencyCode             CHAR(3)       NOT NULL,
        PaymentMethodId          INT           NOT NULL,
        PaymentStatusId          INT           NOT NULL,
        TransferId               UNIQUEIDENTIFIER NULL,
        FailureCode              VARCHAR(50)   NULL,
        FailureMessage           NVARCHAR(400) NULL,
        CreatedAt                DATETIME2(3)  NOT NULL
            CONSTRAINT DF_payment_Payment_CreatedAt DEFAULT (SYSUTCDATETIME()),
        ProcessedAt              DATETIME2(3)  NULL,
        RowVersion               ROWVERSION    NOT NULL,
        CONSTRAINT FK_payment_Payment_Method
            FOREIGN KEY (PaymentMethodId) REFERENCES payment.PaymentMethod (PaymentMethodId),
        CONSTRAINT FK_payment_Payment_Status
            FOREIGN KEY (PaymentStatusId) REFERENCES payment.PaymentStatus (PaymentStatusId),
        CONSTRAINT CK_payment_Payment_Amount
            CHECK (Amount > 0),
        CONSTRAINT CK_payment_Payment_Beneficiary
            CHECK (LEN(LTRIM(RTRIM(BeneficiaryName))) > 0),
        CONSTRAINT CK_payment_Payment_AccountNumber
            CHECK (LEN(LTRIM(RTRIM(BeneficiaryAccountNumber))) BETWEEN 6 AND 34),
        CONSTRAINT CK_payment_Payment_Currency
            CHECK (LEN(CurrencyCode) = 3),
        CONSTRAINT CK_payment_Payment_DifferentAccounts
            CHECK (DebitAccountId <> BeneficiaryAccountId)
    );
END
GO

IF OBJECT_ID(N'payment.PaymentEvent', N'U') IS NULL
BEGIN
    CREATE TABLE payment.PaymentEvent
    (
        PaymentEventId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_payment_PaymentEvent PRIMARY KEY,
        PaymentId      BIGINT        NOT NULL,
        EventType      VARCHAR(30)   NOT NULL,
        EventData      NVARCHAR(MAX) NULL,
        Actor          NVARCHAR(128) NOT NULL
            CONSTRAINT DF_payment_PaymentEvent_Actor DEFAULT (SUSER_SNAME()),
        CreatedAt      DATETIME2(3)  NOT NULL
            CONSTRAINT DF_payment_PaymentEvent_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_payment_PaymentEvent_Payment
            FOREIGN KEY (PaymentId) REFERENCES payment.Payment (PaymentId),
        CONSTRAINT CK_payment_PaymentEvent_EventData
            CHECK (EventData IS NULL OR ISJSON(EventData) = 1)
    );
END
GO

IF OBJECT_ID(N'settlement.SettlementBatch', N'U') IS NULL
BEGIN
    CREATE TABLE settlement.SettlementBatch
    (
        SettlementBatchId BIGINT       IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_settlement_SettlementBatch PRIMARY KEY,
        BatchReference    VARCHAR(24)  NOT NULL
            CONSTRAINT UQ_settlement_SettlementBatch_BatchReference UNIQUE,
        SettlementDate    DATE         NOT NULL,
        Status            VARCHAR(20)  NOT NULL
            CONSTRAINT DF_settlement_SettlementBatch_Status DEFAULT ('OPEN'),
        CreatedAt         DATETIME2(3) NOT NULL
            CONSTRAINT DF_settlement_SettlementBatch_CreatedAt DEFAULT (SYSUTCDATETIME()),
        ClosedAt          DATETIME2(3) NULL,
        CONSTRAINT CK_settlement_SettlementBatch_Status
            CHECK (Status IN ('OPEN', 'CLOSED', 'CANCELLED')),
        CONSTRAINT CK_settlement_SettlementBatch_ClosedAt
            CHECK (ClosedAt IS NULL OR ClosedAt >= CreatedAt)
    );
END
GO

IF OBJECT_ID(N'settlement.SettlementItem', N'U') IS NULL
BEGIN
    CREATE TABLE settlement.SettlementItem
    (
        SettlementItemId  BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_settlement_SettlementItem PRIMARY KEY,
        SettlementBatchId BIGINT        NOT NULL,
        PaymentId         BIGINT        NOT NULL,
        Amount            DECIMAL(19,4) NOT NULL,
        CurrencyCode      CHAR(3)       NOT NULL,
        Status            VARCHAR(20)   NOT NULL
            CONSTRAINT DF_settlement_SettlementItem_Status DEFAULT ('PENDING'),
        CreatedAt         DATETIME2(3)  NOT NULL
            CONSTRAINT DF_settlement_SettlementItem_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_settlement_SettlementItem_Batch
            FOREIGN KEY (SettlementBatchId) REFERENCES settlement.SettlementBatch (SettlementBatchId),
        CONSTRAINT FK_settlement_SettlementItem_Payment
            FOREIGN KEY (PaymentId) REFERENCES payment.Payment (PaymentId),
        CONSTRAINT UQ_settlement_SettlementItem_Batch_Payment
            UNIQUE (SettlementBatchId, PaymentId),
        CONSTRAINT CK_settlement_SettlementItem_Amount
            CHECK (Amount > 0),
        CONSTRAINT CK_settlement_SettlementItem_Status
            CHECK (Status IN ('PENDING', 'SETTLED', 'FAILED', 'CANCELLED'))
    );
END
GO

IF OBJECT_ID(N'audit.AuditEvent', N'U') IS NULL
BEGIN
    CREATE TABLE audit.AuditEvent
    (
        AuditEventId  BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_audit_AuditEvent PRIMARY KEY,
        EventType     VARCHAR(50)   NOT NULL,
        EntityType    VARCHAR(50)   NOT NULL,
        EntityId      NVARCHAR(100) NOT NULL,
        Actor         NVARCHAR(128) NOT NULL
            CONSTRAINT DF_audit_AuditEvent_Actor DEFAULT (SUSER_SNAME()),
        CorrelationId UNIQUEIDENTIFIER NULL,
        EventData     NVARCHAR(MAX) NULL,
        CreatedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_audit_AuditEvent_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_audit_AuditEvent_EventData
            CHECK (EventData IS NULL OR ISJSON(EventData) = 1)
    );
END
GO

PRINT N'AFS_Payments tables created (or already existed).';
GO

SELECT s.name AS schema_name, t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('payment', 'settlement', 'audit')
ORDER BY s.name, t.name;
GO
