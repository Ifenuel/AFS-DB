/*
  AFS-DBA-001
  Purpose: AFS_Identity - human identity, role grants, access reviews and sessions.
  Safety: Idempotent (IF OBJECT_ID ... IS NULL).
  Prerequisites: AFS_Identity exists.
  Run as: AFS_DBA.
*/
USE AFS_Identity;
GO

IF SCHEMA_ID('iam') IS NULL EXEC ('CREATE SCHEMA iam AUTHORIZATION dbo;');
GO

IF OBJECT_ID('iam.Principal') IS NULL
CREATE TABLE iam.Principal
(
    PrincipalId   int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_Principal PRIMARY KEY,
    PrincipalName nvarchar(120) NOT NULL CONSTRAINT UQ_iam_Principal_Name UNIQUE,
    PrincipalType varchar(20)   NOT NULL CONSTRAINT CK_iam_Principal_Type CHECK (PrincipalType IN ('human','service')),
    Department    nvarchar(80)  NOT NULL,
    IsActive      bit           NOT NULL CONSTRAINT DF_iam_Principal_Active DEFAULT (1),
    CreatedAt     datetime2(3)  NOT NULL CONSTRAINT DF_iam_Principal_Created DEFAULT (SYSUTCDATETIME())
);
GO

IF OBJECT_ID('iam.Role') IS NULL
CREATE TABLE iam.Role
(
    RoleId       int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_Role PRIMARY KEY,
    RoleName     nvarchar(80)  NOT NULL CONSTRAINT UQ_iam_Role_Name UNIQUE,
    Description  nvarchar(300) NOT NULL,
    IsPrivileged bit           NOT NULL CONSTRAINT DF_iam_Role_Priv DEFAULT (0)
);
GO

IF OBJECT_ID('iam.RoleAssignment') IS NULL
CREATE TABLE iam.RoleAssignment
(
    RoleAssignmentId int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_RoleAssignment PRIMARY KEY,
    PrincipalId      int          NOT NULL,
    RoleId           int          NOT NULL,
    GrantedAt        datetime2(3) NOT NULL CONSTRAINT DF_iam_RoleAssignment_Granted DEFAULT (SYSUTCDATETIME()),
    GrantedBy        nvarchar(120) NOT NULL,
    ExpiresAt        datetime2(3) NULL,
    IsActive         bit          NOT NULL CONSTRAINT DF_iam_RoleAssignment_Active DEFAULT (1),
    CONSTRAINT FK_iam_RoleAssignment_Principal FOREIGN KEY (PrincipalId) REFERENCES iam.Principal (PrincipalId),
    CONSTRAINT FK_iam_RoleAssignment_Role      FOREIGN KEY (RoleId)      REFERENCES iam.Role (RoleId)
);
GO

IF OBJECT_ID('iam.AccessRequest') IS NULL
CREATE TABLE iam.AccessRequest
(
    AccessRequestId      int           IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_AccessRequest PRIMARY KEY,
    PrincipalId          int           NOT NULL,
    RoleId               int           NOT NULL,
    RequestedAt          datetime2(3)  NOT NULL,
    BusinessJustification nvarchar(400) NOT NULL,
    Approver             nvarchar(120) NULL,
    ApprovedAt           datetime2(3)  NULL,
    Status               varchar(12)   NOT NULL CONSTRAINT CK_iam_AccessRequest_Status
                         CHECK (Status IN ('pending','approved','rejected','expired')),
    CONSTRAINT FK_iam_AccessRequest_Principal FOREIGN KEY (PrincipalId) REFERENCES iam.Principal (PrincipalId),
    CONSTRAINT FK_iam_AccessRequest_Role      FOREIGN KEY (RoleId)      REFERENCES iam.Role (RoleId)
);
GO

IF OBJECT_ID('iam.AccessReview') IS NULL
CREATE TABLE iam.AccessReview
(
    AccessReviewId int          IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_AccessReview PRIMARY KEY,
    ReviewPeriod   date         NOT NULL,
    Scope          nvarchar(200) NOT NULL,
    Reviewer       nvarchar(120) NOT NULL,
    CompletedAt    datetime2(3) NULL
);
GO

IF OBJECT_ID('iam.AccessReviewDecision') IS NULL
CREATE TABLE iam.AccessReviewDecision
(
    AccessReviewDecisionId int         IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_AccessReviewDecision PRIMARY KEY,
    AccessReviewId         int         NOT NULL,
    RoleAssignmentId       int         NOT NULL,
    Decision               varchar(8)  NOT NULL CONSTRAINT CK_iam_Decision_Value CHECK (Decision IN ('retain','revoke')),
    DecidedAt              datetime2(3) NOT NULL,
    Note                   nvarchar(300) NULL,
    CONSTRAINT FK_iam_Decision_Review     FOREIGN KEY (AccessReviewId)   REFERENCES iam.AccessReview (AccessReviewId),
    CONSTRAINT FK_iam_Decision_Assignment FOREIGN KEY (RoleAssignmentId) REFERENCES iam.RoleAssignment (RoleAssignmentId)
);
GO

IF OBJECT_ID('iam.SessionEvent') IS NULL
CREATE TABLE iam.SessionEvent
(
    SessionEventId bigint       IDENTITY(1,1) NOT NULL CONSTRAINT PK_iam_SessionEvent PRIMARY KEY,
    PrincipalId    int          NOT NULL,
    DatabaseName   nvarchar(80) NOT NULL,
    StartedAt      datetime2(3) NOT NULL,
    EndedAt        datetime2(3) NULL,
    ClientHost     nvarchar(80) NOT NULL,
    AuthMethod     varchar(20)  NOT NULL CONSTRAINT CK_iam_Session_Auth
                   CHECK (AuthMethod IN ('windows','certificate','sql','token')),
    CONSTRAINT FK_iam_Session_Principal FOREIGN KEY (PrincipalId) REFERENCES iam.Principal (PrincipalId)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_iam_Session_Principal_Started')
    CREATE INDEX IX_iam_Session_Principal_Started ON iam.SessionEvent (PrincipalId, StartedAt DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_iam_Assignment_Role_Active')
    CREATE INDEX IX_iam_Assignment_Role_Active ON iam.RoleAssignment (RoleId, IsActive) INCLUDE (PrincipalId, ExpiresAt);
GO
