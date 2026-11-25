/*
  AFS-DBA-001
  Purpose: Create AFS_Fraud tables.
  Safety: Idempotent at table level.
*/

USE [AFS_Fraud];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'fraud.FraudRule', N'U') IS NULL
BEGIN
    CREATE TABLE fraud.FraudRule
    (
        FraudRuleId   INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_fraud_FraudRule PRIMARY KEY,
        RuleCode      VARCHAR(30)   NOT NULL
            CONSTRAINT UQ_fraud_FraudRule_RuleCode UNIQUE,
        RuleName      NVARCHAR(200) NOT NULL,
        ThresholdAmount DECIMAL(19,4) NULL,
        WindowMinutes INT           NULL,
        IsActive      BIT           NOT NULL
            CONSTRAINT DF_fraud_FraudRule_IsActive DEFAULT (1),
        CreatedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_fraud_FraudRule_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_fraud_FraudRule_Threshold
            CHECK (ThresholdAmount IS NULL OR ThresholdAmount > 0),
        CONSTRAINT CK_fraud_FraudRule_Window
            CHECK (WindowMinutes IS NULL OR WindowMinutes > 0)
    );
END
GO

IF OBJECT_ID(N'fraud.FraudAlert', N'U') IS NULL
BEGIN
    CREATE TABLE fraud.FraudAlert
    (
        FraudAlertId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_fraud_FraudAlert PRIMARY KEY,
        FraudRuleId  INT           NOT NULL,
        CustomerId   BIGINT        NULL,
        AccountId    BIGINT        NULL,
        TransferId   UNIQUEIDENTIFIER NULL,
        Amount       DECIMAL(19,4) NULL,
        Status       VARCHAR(20)   NOT NULL
            CONSTRAINT DF_fraud_FraudAlert_Status DEFAULT ('OPEN'),
        Details      NVARCHAR(MAX) NULL,
        CreatedAt    DATETIME2(3)  NOT NULL
            CONSTRAINT DF_fraud_FraudAlert_CreatedAt DEFAULT (SYSUTCDATETIME()),
        ResolvedAt   DATETIME2(3)  NULL,
        CONSTRAINT FK_fraud_FraudAlert_Rule
            FOREIGN KEY (FraudRuleId) REFERENCES fraud.FraudRule (FraudRuleId),
        CONSTRAINT CK_fraud_FraudAlert_Status
            CHECK (Status IN ('OPEN', 'IN_REVIEW', 'CLOSED_FALSE_POSITIVE', 'CLOSED_CONFIRMED')),
        CONSTRAINT CK_fraud_FraudAlert_Amount
            CHECK (Amount IS NULL OR Amount > 0),
        CONSTRAINT CK_fraud_FraudAlert_ResolvedAt
            CHECK (ResolvedAt IS NULL OR ResolvedAt >= CreatedAt)
    );
END
GO

IF OBJECT_ID(N'fraud.FraudCase', N'U') IS NULL
BEGIN
    CREATE TABLE fraud.FraudCase
    (
        FraudCaseId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_fraud_FraudCase PRIMARY KEY,
        FraudAlertId BIGINT       NOT NULL,
        Investigator NVARCHAR(128) NULL,
        Status       VARCHAR(20)  NOT NULL
            CONSTRAINT DF_fraud_FraudCase_Status DEFAULT ('OPEN'),
        Findings     NVARCHAR(MAX) NULL,
        OpenedAt     DATETIME2(3) NOT NULL
            CONSTRAINT DF_fraud_FraudCase_OpenedAt DEFAULT (SYSUTCDATETIME()),
        ClosedAt     DATETIME2(3) NULL,
        CONSTRAINT FK_fraud_FraudCase_Alert
            FOREIGN KEY (FraudAlertId) REFERENCES fraud.FraudAlert (FraudAlertId),
        CONSTRAINT CK_fraud_FraudCase_Status
            CHECK (Status IN ('OPEN', 'INVESTIGATING', 'CLOSED')),
        CONSTRAINT CK_fraud_FraudCase_ClosedAt
            CHECK (ClosedAt IS NULL OR ClosedAt >= OpenedAt)
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

PRINT N'AFS_Fraud tables created (or already existed).';
GO
