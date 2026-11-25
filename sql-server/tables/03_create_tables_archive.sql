/*
  AFS-DBA-001
  Purpose: AFS_Archive - tamper-evident retention with a SHA-256 hash chain.
  Safety: Idempotent (IF OBJECT_ID ... IS NULL).
  Prerequisites: AFS_Archive exists.
  Run as: AFS_DBA.
*/
USE AFS_Archive;
GO

IF SCHEMA_ID('retention') IS NULL EXEC ('CREATE SCHEMA retention AUTHORIZATION dbo;');
GO

IF OBJECT_ID('retention.RetentionPolicy') IS NULL
CREATE TABLE retention.RetentionPolicy
(
    RetentionPolicyId int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_retention_Policy PRIMARY KEY,
    PolicyName        varchar(60)  NOT NULL CONSTRAINT UQ_retention_Policy_Name UNIQUE,
    DataClass         varchar(40)  NOT NULL,
    RetentionMonths   int          NOT NULL CONSTRAINT CK_retention_Policy_Months CHECK (RetentionMonths BETWEEN 6 AND 240),
    LegalBasis        varchar(80)  NOT NULL
);
GO

IF OBJECT_ID('retention.ArchivedRecord') IS NULL
CREATE TABLE retention.ArchivedRecord
(
    ArchivedRecordId bigint       IDENTITY(1,1) NOT NULL CONSTRAINT PK_retention_Record PRIMARY KEY,
    SourceDatabase   nvarchar(80) NOT NULL,
    SourceTable      nvarchar(80) NOT NULL,
    RecordKey        nvarchar(80) NOT NULL,
    PayloadHash      char(64)     NOT NULL,
    PreviousHash     char(64)     NOT NULL,
    ArchivedAt       datetime2(3) NOT NULL,
    RetentionPolicyId int         NOT NULL,
    IsPurged         bit          NOT NULL CONSTRAINT DF_retention_Record_Purged DEFAULT (0),
    CONSTRAINT FK_retention_Record_Policy FOREIGN KEY (RetentionPolicyId)
        REFERENCES retention.RetentionPolicy (RetentionPolicyId)
);
GO

IF OBJECT_ID('retention.LegalHold') IS NULL
CREATE TABLE retention.LegalHold
(
    LegalHoldId    int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_retention_Hold PRIMARY KEY,
    MatterReference varchar(40)  NOT NULL CONSTRAINT UQ_retention_Hold_Matter UNIQUE,
    Custodian      nvarchar(120) NOT NULL,
    PlacedAt       datetime2(3)  NOT NULL,
    ReleasedAt     datetime2(3)  NULL
);
GO

IF OBJECT_ID('retention.LegalHoldRecord') IS NULL
CREATE TABLE retention.LegalHoldRecord
(
    LegalHoldRecordId int    IDENTITY(1,1) NOT NULL CONSTRAINT PK_retention_HoldRecord PRIMARY KEY,
    LegalHoldId       int    NOT NULL,
    ArchivedRecordId  bigint NOT NULL,
    CONSTRAINT UQ_retention_HoldRecord UNIQUE (LegalHoldId, ArchivedRecordId),
    CONSTRAINT FK_retention_HoldRecord_Hold   FOREIGN KEY (LegalHoldId)      REFERENCES retention.LegalHold (LegalHoldId),
    CONSTRAINT FK_retention_HoldRecord_Record FOREIGN KEY (ArchivedRecordId) REFERENCES retention.ArchivedRecord (ArchivedRecordId)
);
GO

IF OBJECT_ID('retention.PurgeRun') IS NULL
CREATE TABLE retention.PurgeRun
(
    PurgeRunId        int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_retention_PurgeRun PRIMARY KEY,
    RunAt             datetime2(3) NOT NULL,
    RetentionPolicyId int          NOT NULL,
    Candidates        int          NOT NULL,
    Purged            int          NOT NULL,
    BlockedByHold     int          NOT NULL,
    CONSTRAINT FK_retention_Purge_Policy FOREIGN KEY (RetentionPolicyId)
        REFERENCES retention.RetentionPolicy (RetentionPolicyId)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_retention_Record_Policy_Archived')
    CREATE INDEX IX_retention_Record_Policy_Archived ON retention.ArchivedRecord (RetentionPolicyId, ArchivedAt);
GO
