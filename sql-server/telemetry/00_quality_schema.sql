/*
  AFS-DBA-001
  P-02 oilfield telemetry data quality — schema
  Adds a staging and quality layer around the existing historian
  (AFS_Archive.telemetry.Reading / Tag / Gap / CollectorRun) without changing
  the meaning of the readings already stored.

  All data is synthetic: values come from tools/ot/plc_sim.py and are injected
  with faults by tools/ot/fault_collector.py.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
USE AFS_Archive;
GO

/* Trace which laboratory run produced a reading, so it can be reset and audited. */
IF COL_LENGTH('telemetry.Reading', 'SourceRunId') IS NULL
    ALTER TABLE telemetry.Reading ADD SourceRunId int NULL;
GO

IF OBJECT_ID('telemetry.Staging') IS NULL
CREATE TABLE telemetry.Staging
(
    StagingId     bigint IDENTITY(1,1) NOT NULL,
    RunId         int                NOT NULL,
    TagCode       varchar(30)        NOT NULL,
    SourceId      varchar(30)        NOT NULL,
    ObservedAt    datetime2(7)       NOT NULL,
    ReceivedAt    datetime2(7)       NOT NULL,
    RawValue      decimal(18,6)      NULL,
    RawUnit       varchar(12)        NULL,
    Payload       nvarchar(300)      NULL,
    Outcome       varchar(20)        NULL,   -- NULL = pending
    OutcomeDetail nvarchar(200)      NULL,
    CONSTRAINT PK_telemetry_Staging PRIMARY KEY (StagingId),
    CONSTRAINT CK_telemetry_Staging_Outcome CHECK
        (Outcome IS NULL OR Outcome IN ('VALID','VALID_LATE','VALID_OUT_OF_ORDER','DUPLICATE','INVALID'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_telemetry_Staging_Run')
    CREATE INDEX IX_telemetry_Staging_Run ON telemetry.Staging(RunId, TagCode, ObservedAt);
GO

IF OBJECT_ID('telemetry.Quarantine') IS NULL
CREATE TABLE telemetry.Quarantine
(
    QuarantineId bigint IDENTITY(1,1) NOT NULL,
    RunId        int                NOT NULL,
    StagingId    bigint             NOT NULL,
    TagCode      varchar(30)        NOT NULL,
    SourceId     varchar(30)        NOT NULL,
    ObservedAt   datetime2(7)       NOT NULL,
    RawValue     decimal(18,6)      NULL,
    RawUnit      varchar(12)        NULL,
    Reason       varchar(40)        NOT NULL,
    Detail       nvarchar(200)      NULL,
    CreatedAt    datetime2(7)       NOT NULL CONSTRAINT DF_telemetry_Quarantine_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_telemetry_Quarantine PRIMARY KEY (QuarantineId),
    CONSTRAINT FK_telemetry_Quarantine_Staging FOREIGN KEY (StagingId)
        REFERENCES telemetry.Staging(StagingId)
);
GO

IF OBJECT_ID('telemetry.Correction') IS NULL
CREATE TABLE telemetry.Correction
(
    CorrectionId bigint IDENTITY(1,1) NOT NULL,
    ReadingId    bigint               NOT NULL,
    OldValue     decimal(10,3)        NOT NULL,
    NewValue     decimal(10,3)        NOT NULL,
    Reason       nvarchar(300)        NOT NULL,
    Actor        nvarchar(128)        NOT NULL,
    CreatedAt    datetime2(7)         NOT NULL CONSTRAINT DF_telemetry_Correction_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_telemetry_Correction PRIMARY KEY (CorrectionId),
    CONSTRAINT FK_telemetry_Correction_Reading FOREIGN KEY (ReadingId)
        REFERENCES telemetry.Reading(ReadingId)
);
GO

IF OBJECT_ID('telemetry.CompletenessScore') IS NULL
CREATE TABLE telemetry.CompletenessScore
(
    ScoreId       bigint IDENTITY(1,1) NOT NULL,
    RunId         int                NOT NULL,
    TagCode       varchar(30)        NOT NULL,
    IntervalStart datetime2(7)       NOT NULL,
    IntervalEnd   datetime2(7)       NOT NULL,
    Observed      int                NOT NULL,
    Expected      decimal(10,2)      NOT NULL,
    CompletenessRatio decimal(6,4)   NOT NULL,
    MaxGapSeconds decimal(10,3)      NOT NULL,
    GapProbability decimal(8,6)      NOT NULL,
    Method        varchar(120)       NOT NULL,
    CONSTRAINT PK_telemetry_CompletenessScore PRIMARY KEY (ScoreId)
);
GO

/* Effective value: the accepted reading, overridden by the latest correction.
   Original readings are never destroyed, so every change is reversible. */
CREATE OR ALTER VIEW telemetry.vw_EffectiveReading
AS
SELECT r.ReadingId, r.TagId, t.TagCode, r.ObservedAt, r.Quality, r.SourceRunId,
       /* the original is the earliest recorded OldValue; Reading.Value is current */
       ISNULL(o.OldValue, r.Value) AS OriginalValue,
       ISNULL(c.NewValue, r.Value) AS EffectiveValue,
       CASE WHEN c.CorrectionId IS NULL THEN 0 ELSE 1 END AS IsCorrected,
       c.Reason AS CorrectionReason
FROM telemetry.Reading r
JOIN telemetry.Tag t ON t.TagId = r.TagId
OUTER APPLY (
    SELECT TOP (1) c.OldValue
    FROM telemetry.Correction c
    WHERE c.ReadingId = r.ReadingId
    ORDER BY c.CorrectionId ASC
) o
OUTER APPLY (
    SELECT TOP (1) c.CorrectionId, c.NewValue, c.Reason
    FROM telemetry.Correction c
    WHERE c.ReadingId = r.ReadingId
    ORDER BY c.CorrectionId DESC
) c;
GO

PRINT 'telemetry quality schema ready';
GO
