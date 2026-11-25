/*
  AFS-DBA-001
  Purpose: Historian schema for plant telemetry in the retention database.
  Safety: Idempotent (creates schema, tables and seed tags only when absent).
*/
/* Historian schema for operational telemetry.
   The archive database already owns retention, so time-series data lives here:
   a small tag dictionary, one row per reading, one row per collector run, and a
   row for every window in which the collector could not reach the plant. */
SET NOCOUNT ON;
USE AFS_Archive;
GO
IF SCHEMA_ID('telemetry') IS NULL EXEC ('CREATE SCHEMA telemetry');
GO
IF OBJECT_ID('telemetry.Tag') IS NULL
BEGIN
    CREATE TABLE telemetry.Tag
    (
        TagId        smallint      IDENTITY(1,1) NOT NULL,
        TagCode      varchar(30)   NOT NULL,
        Description  varchar(120)  NOT NULL,
        Unit         varchar(12)   NOT NULL,
        PlcRegister  int           NOT NULL,
        NominalLow   decimal(10,3) NOT NULL,
        NominalHigh  decimal(10,3) NOT NULL,
        CONSTRAINT PK_Tag PRIMARY KEY CLUSTERED (TagId),
        CONSTRAINT UQ_Tag_Code UNIQUE (TagCode),
        CONSTRAINT UQ_Tag_Register UNIQUE (PlcRegister),
        CONSTRAINT CK_Tag_Range CHECK (NominalLow < NominalHigh)
    );
    PRINT 'created telemetry.Tag';
END
GO
IF OBJECT_ID('telemetry.CollectorRun') IS NULL
BEGIN
    CREATE TABLE telemetry.CollectorRun
    (
        RunId           int          IDENTITY(1,1) NOT NULL,
        StartedAt       datetime2(3) NOT NULL,
        EndedAt         datetime2(3) NULL,
        IntervalMs      int          NOT NULL,
        ReadingsWritten int          NOT NULL CONSTRAINT DF_CollectorRun_Readings DEFAULT (0),
        GapsDetected    int          NOT NULL CONSTRAINT DF_CollectorRun_Gaps DEFAULT (0),
        Notes           varchar(200) NULL,
        CONSTRAINT PK_CollectorRun PRIMARY KEY CLUSTERED (RunId),
        CONSTRAINT CK_CollectorRun_Interval CHECK (IntervalMs BETWEEN 100 AND 60000)
    );
    PRINT 'created telemetry.CollectorRun';
END
GO
IF OBJECT_ID('telemetry.Reading') IS NULL
BEGIN
    CREATE TABLE telemetry.Reading
    (
        ReadingId  bigint        IDENTITY(1,1) NOT NULL,
        TagId      smallint      NOT NULL,
        ObservedAt datetime2(3)  NOT NULL,
        Value      decimal(10,3) NOT NULL,
        Quality    tinyint       NOT NULL CONSTRAINT DF_Reading_Quality DEFAULT (192),
        CONSTRAINT PK_Reading PRIMARY KEY CLUSTERED (ReadingId),
        CONSTRAINT FK_Reading_Tag FOREIGN KEY (TagId) REFERENCES telemetry.Tag (TagId)
    );
    CREATE INDEX IX_Reading_TagTime ON telemetry.Reading (TagId, ObservedAt);
    PRINT 'created telemetry.Reading';
END
GO
IF OBJECT_ID('telemetry.Gap') IS NULL
BEGIN
    CREATE TABLE telemetry.Gap
    (
        GapId          int          IDENTITY(1,1) NOT NULL,
        RunId          int          NOT NULL,
        TagId          smallint     NULL,
        GapStart       datetime2(3) NOT NULL,
        GapEnd         datetime2(3) NOT NULL,
        MissedReadings int          NOT NULL,
        DetectedAt     datetime2(3) NOT NULL CONSTRAINT DF_Gap_DetectedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_Gap PRIMARY KEY CLUSTERED (GapId),
        CONSTRAINT FK_Gap_Run FOREIGN KEY (RunId) REFERENCES telemetry.CollectorRun (RunId),
        CONSTRAINT FK_Gap_Tag FOREIGN KEY (TagId) REFERENCES telemetry.Tag (TagId),
        CONSTRAINT CK_Gap_Window CHECK (GapEnd >= GapStart)
    );
    PRINT 'created telemetry.Gap';
END
GO
IF NOT EXISTS (SELECT 1 FROM telemetry.Tag)
BEGIN
    INSERT INTO telemetry.Tag (TagCode, Description, Unit, PlcRegister, NominalLow, NominalHigh)
    VALUES ('WELLHEAD_PRESS', 'Wellhead pressure', 'bar', 0, 60.000, 90.000),
           ('FLOW_RATE',     'Separator inlet flow', 'm3/h', 1, 30.000, 55.000),
           ('SEP_TEMP',      'Separator temperature', 'C', 2, 55.000, 75.000);
    PRINT 'seeded 3 tags';
END
GO
SELECT COUNT(*) AS tags FROM telemetry.Tag;
GO
