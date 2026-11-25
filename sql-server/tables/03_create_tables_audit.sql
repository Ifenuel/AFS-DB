/*
  AFS-DBA-001
  Purpose: Create AFS_Audit tables. These are append-oriented.
  Safety: Idempotent at table level.
*/

USE [AFS_Audit];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'security.SecurityEvent', N'U') IS NULL
BEGIN
    CREATE TABLE security.SecurityEvent
    (
        SecurityEventId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_security_SecurityEvent PRIMARY KEY,
        EventTime       DATETIME2(3)  NOT NULL
            CONSTRAINT DF_security_SecurityEvent_EventTime DEFAULT (SYSUTCDATETIME()),
        EventType       VARCHAR(50)   NOT NULL,
        PrincipalName   NVARCHAR(128) NOT NULL,
        ClientHost      NVARCHAR(128) NULL,
        Success         BIT           NOT NULL,
        Details         NVARCHAR(1000) NULL,
        CorrelationId   UNIQUEIDENTIFIER NULL,
        CONSTRAINT CK_security_SecurityEvent_EventType
            CHECK (LEN(LTRIM(RTRIM(EventType))) > 0)
    );
END
GO

IF OBJECT_ID(N'administration.AdminAction', N'U') IS NULL
BEGIN
    CREATE TABLE administration.AdminAction
    (
        AdminActionId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_administration_AdminAction PRIMARY KEY,
        ActionTime    DATETIME2(3)  NOT NULL
            CONSTRAINT DF_administration_AdminAction_ActionTime DEFAULT (SYSUTCDATETIME()),
        AdminPrincipal NVARCHAR(128) NOT NULL,
        ActionType    VARCHAR(50)   NOT NULL,
        ObjectName    NVARCHAR(256) NULL,
        Details       NVARCHAR(MAX) NULL,
        CorrelationId UNIQUEIDENTIFIER NULL,
        CONSTRAINT CK_administration_AdminAction_Type
            CHECK (LEN(LTRIM(RTRIM(ActionType))) > 0)
    );
END
GO

IF OBJECT_ID(N'operational.JobRun', N'U') IS NULL
BEGIN
    CREATE TABLE operational.JobRun
    (
        JobRunId   BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_operational_JobRun PRIMARY KEY,
        JobName    NVARCHAR(128) NOT NULL,
        StartTime  DATETIME2(3)  NOT NULL,
        EndTime    DATETIME2(3)  NULL,
        Status     VARCHAR(20)   NOT NULL,
        Message    NVARCHAR(MAX) NULL,
        CONSTRAINT CK_operational_JobRun_Status
            CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'SKIPPED')),
        CONSTRAINT CK_operational_JobRun_EndTime
            CHECK (EndTime IS NULL OR EndTime >= StartTime)
    );
END
GO

IF OBJECT_ID(N'operational.BackupHistory', N'U') IS NULL
BEGIN
    CREATE TABLE operational.BackupHistory
    (
        BackupHistoryId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_operational_BackupHistory PRIMARY KEY,
        DatabaseName    SYSNAME       NOT NULL,
        -- DIFFERENTIAL is 12 characters; VARCHAR(10) truncated the audit row.
        BackupType      VARCHAR(20)   NOT NULL,
        BackupPath      NVARCHAR(500) NOT NULL,
        StartedAt       DATETIME2(3)  NOT NULL,
        CompletedAt     DATETIME2(3)  NULL,
        SizeMB          DECIMAL(19,2) NULL,
        IsVerified      BIT           NOT NULL
            CONSTRAINT DF_operational_BackupHistory_IsVerified DEFAULT (0),
        VerificationTime DATETIME2(3) NULL,
        Message         NVARCHAR(MAX) NULL,
        CONSTRAINT CK_operational_BackupHistory_Type
            CHECK (BackupType IN ('FULL', 'DIFFERENTIAL', 'LOG', 'COPY_ONLY')),
        CONSTRAINT CK_operational_BackupHistory_CompletedAt
            CHECK (CompletedAt IS NULL OR CompletedAt >= StartedAt)
    );
END
GO

-- Migration for an existing lab database created before BackupType was widened.
IF COL_LENGTH(N'operational.BackupHistory', N'BackupType') = 10
    ALTER TABLE operational.BackupHistory ALTER COLUMN BackupType VARCHAR(20) NOT NULL;
GO

IF OBJECT_ID(N'audit.AuditRecord', N'U') IS NULL
BEGIN
    CREATE TABLE audit.AuditRecord
    (
        AuditRecordId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_audit_AuditRecord PRIMARY KEY,
        EventTime     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_audit_AuditRecord_EventTime DEFAULT (SYSUTCDATETIME()),
        SourceDatabase SYSNAME      NOT NULL,
        EventType     VARCHAR(50)   NOT NULL,
        EntityType    VARCHAR(50)   NOT NULL,
        EntityId      NVARCHAR(100) NOT NULL,
        Actor         NVARCHAR(128) NOT NULL,
        CorrelationId UNIQUEIDENTIFIER NULL,
        EventData     NVARCHAR(MAX) NULL,
        CreatedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_audit_AuditRecord_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_audit_AuditRecord_EventData
            CHECK (EventData IS NULL OR ISJSON(EventData) = 1)
    );
END
GO

PRINT N'AFS_Audit tables created (or already existed).';
GO
