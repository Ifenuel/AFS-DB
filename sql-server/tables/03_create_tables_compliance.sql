/*
  AFS-DBA-001
  Purpose: AFS_Compliance - obligations, controls, tests, findings and remediation.
  Safety: Idempotent (IF OBJECT_ID ... IS NULL).
  Prerequisites: AFS_Compliance exists.
  Run as: AFS_DBA.
*/
USE AFS_Compliance;
GO

IF SCHEMA_ID('grc') IS NULL EXEC ('CREATE SCHEMA grc AUTHORIZATION dbo;');
GO

IF OBJECT_ID('grc.Obligation') IS NULL
CREATE TABLE grc.Obligation
(
    ObligationId int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_grc_Obligation PRIMARY KEY,
    Framework    varchar(20)   NOT NULL CONSTRAINT CK_grc_Obligation_Framework
                 CHECK (Framework IN ('DORA','CBN','PCI DSS','ISO 27001','NIST CSF')),
    Reference    varchar(40)   NOT NULL,
    Requirement  nvarchar(400) NOT NULL,
    CONSTRAINT UQ_grc_Obligation UNIQUE (Framework, Reference)
);
GO

IF OBJECT_ID('grc.Control') IS NULL
CREATE TABLE grc.Control
(
    ControlId   int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_grc_Control PRIMARY KEY,
    ControlCode varchar(20)   NOT NULL CONSTRAINT UQ_grc_Control_Code UNIQUE,
    Title       nvarchar(200) NOT NULL,
    ControlType varchar(12)   NOT NULL CONSTRAINT CK_grc_Control_Type CHECK (ControlType IN ('preventive','detective')),
    Owner       nvarchar(120) NOT NULL,
    Frequency   varchar(12)   NOT NULL CONSTRAINT CK_grc_Control_Freq CHECK (Frequency IN ('continuous','daily','monthly','quarterly','annual'))
);
GO

IF OBJECT_ID('grc.ControlObligation') IS NULL
CREATE TABLE grc.ControlObligation
(
    ControlObligationId int NOT NULL CONSTRAINT PK_grc_ControlObligation PRIMARY KEY,
    ControlId           int NOT NULL,
    ObligationId        int NOT NULL,
    CONSTRAINT UQ_grc_ControlObligation UNIQUE (ControlId, ObligationId),
    CONSTRAINT FK_grc_Mapping_Control    FOREIGN KEY (ControlId)    REFERENCES grc.Control (ControlId),
    CONSTRAINT FK_grc_Mapping_Obligation FOREIGN KEY (ObligationId) REFERENCES grc.Obligation (ObligationId)
);
GO

IF OBJECT_ID('grc.ControlTest') IS NULL
CREATE TABLE grc.ControlTest
(
    ControlTestId int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_grc_ControlTest PRIMARY KEY,
    ControlId     int          NOT NULL,
    TestedAt      datetime2(3) NOT NULL,
    Tester        nvarchar(120) NOT NULL,
    Result        varchar(8)   NOT NULL CONSTRAINT CK_grc_Test_Result CHECK (Result IN ('pass','fail')),
    SampleSize    int          NOT NULL CONSTRAINT CK_grc_Test_Sample CHECK (SampleSize > 0),
    Exceptions    int          NOT NULL CONSTRAINT DF_grc_Test_Exceptions DEFAULT (0),
    EvidenceRef   nvarchar(120) NULL,
    CONSTRAINT FK_grc_Test_Control FOREIGN KEY (ControlId) REFERENCES grc.Control (ControlId)
);
GO

IF OBJECT_ID('grc.Finding') IS NULL
CREATE TABLE grc.Finding
(
    FindingId     int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_grc_Finding PRIMARY KEY,
    ControlTestId int          NOT NULL,
    Severity      varchar(10)  NOT NULL CONSTRAINT CK_grc_Finding_Severity CHECK (Severity IN ('low','medium','high','critical')),
    Description   nvarchar(400) NOT NULL,
    RaisedAt      datetime2(3) NOT NULL,
    Status        varchar(12)  NOT NULL CONSTRAINT CK_grc_Finding_Status CHECK (Status IN ('open','remediating','closed','accepted')),
    CONSTRAINT FK_grc_Finding_Test FOREIGN KEY (ControlTestId) REFERENCES grc.ControlTest (ControlTestId)
);
GO

IF OBJECT_ID('grc.Remediation') IS NULL
CREATE TABLE grc.Remediation
(
    RemediationId int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_grc_Remediation PRIMARY KEY,
    FindingId     int          NOT NULL,
    Action        nvarchar(400) NOT NULL,
    Owner         nvarchar(120) NOT NULL,
    DueAt         date         NOT NULL,
    ClosedAt      date         NULL,
    CONSTRAINT FK_grc_Remediation_Finding FOREIGN KEY (FindingId) REFERENCES grc.Finding (FindingId)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grc_Test_Control_Date')
    CREATE INDEX IX_grc_Test_Control_Date ON grc.ControlTest (ControlId, TestedAt DESC) INCLUDE (Result, Exceptions);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_grc_Finding_Open')
    CREATE INDEX IX_grc_Finding_Open ON grc.Finding (Status, Severity) INCLUDE (ControlTestId, RaisedAt);
GO
