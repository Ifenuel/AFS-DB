/*
  AFS-DBA-001
  Purpose: Create AFS_CustomerService tables.
  Safety: Idempotent at table level.
*/

USE [AFS_CustomerService];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'support.CaseCategory', N'U') IS NULL
BEGIN
    CREATE TABLE support.CaseCategory
    (
        CaseCategoryId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_support_CaseCategory PRIMARY KEY,
        CategoryCode   VARCHAR(30)   NOT NULL
            CONSTRAINT UQ_support_CaseCategory_CategoryCode UNIQUE,
        CategoryName   NVARCHAR(100) NOT NULL,
        IsActive       BIT           NOT NULL
            CONSTRAINT DF_support_CaseCategory_IsActive DEFAULT (1)
    );
END
GO

IF OBJECT_ID(N'support.SupportCase', N'U') IS NULL
BEGIN
    CREATE TABLE support.SupportCase
    (
        CaseId       BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_support_SupportCase PRIMARY KEY,
        CaseNumber   VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_support_SupportCase_CaseNumber UNIQUE,
        CustomerId   BIGINT        NOT NULL, -- cross-database reference to Core
        CaseCategoryId INT         NOT NULL,
        Priority     VARCHAR(10)   NOT NULL
            CONSTRAINT DF_support_SupportCase_Priority DEFAULT ('NORMAL'),
        Status       VARCHAR(20)   NOT NULL
            CONSTRAINT DF_support_SupportCase_Status DEFAULT ('OPEN'),
        Subject      NVARCHAR(200) NOT NULL,
        Description  NVARCHAR(MAX) NULL,
        OpenedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_support_SupportCase_OpenedAt DEFAULT (SYSUTCDATETIME()),
        ClosedAt     DATETIME2(3)  NULL,
        AssignedTo   NVARCHAR(128) NULL,
        RowVersion   ROWVERSION    NOT NULL,
        CONSTRAINT FK_support_SupportCase_Category
            FOREIGN KEY (CaseCategoryId) REFERENCES support.CaseCategory (CaseCategoryId),
        CONSTRAINT CK_support_SupportCase_Priority
            CHECK (Priority IN ('LOW', 'NORMAL', 'HIGH', 'URGENT')),
        CONSTRAINT CK_support_SupportCase_Status
            CHECK (Status IN ('OPEN', 'IN_PROGRESS', 'PENDING_CUSTOMER', 'RESOLVED', 'CLOSED')),
        CONSTRAINT CK_support_SupportCase_ClosedAt
            CHECK (ClosedAt IS NULL OR ClosedAt >= OpenedAt)
    );
END
GO

IF OBJECT_ID(N'support.CaseNote', N'U') IS NULL
BEGIN
    CREATE TABLE support.CaseNote
    (
        CaseNoteId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_support_CaseNote PRIMARY KEY,
        CaseId     BIGINT        NOT NULL,
        Author     NVARCHAR(128) NOT NULL,
        NoteText   NVARCHAR(MAX) NOT NULL,
        CreatedAt  DATETIME2(3)  NOT NULL
            CONSTRAINT DF_support_CaseNote_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_support_CaseNote_Case
            FOREIGN KEY (CaseId) REFERENCES support.SupportCase (CaseId),
        CONSTRAINT CK_support_CaseNote_Text
            CHECK (LEN(LTRIM(RTRIM(NoteText))) > 0)
    );
END
GO

IF OBJECT_ID(N'service_request.ServiceRequest', N'U') IS NULL
BEGIN
    CREATE TABLE service_request.ServiceRequest
    (
        ServiceRequestId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_service_request_ServiceRequest PRIMARY KEY,
        RequestNumber    VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_service_request_ServiceRequest_RequestNumber UNIQUE,
        CaseId           BIGINT        NULL,
        RequestType      VARCHAR(30)   NOT NULL,
        Status           VARCHAR(20)   NOT NULL
            CONSTRAINT DF_service_request_ServiceRequest_Status DEFAULT ('OPEN'),
        Details          NVARCHAR(MAX) NULL,
        CreatedAt        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_service_request_ServiceRequest_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CompletedAt      DATETIME2(3)  NULL,
        CONSTRAINT FK_service_request_ServiceRequest_Case
            FOREIGN KEY (CaseId) REFERENCES support.SupportCase (CaseId),
        CONSTRAINT CK_service_request_ServiceRequest_Type
            CHECK (RequestType IN ('STATEMENT', 'ADDRESS_CHANGE', 'CARD_REPLACEMENT', 'ACCOUNT_CLOSURE', 'OTHER')),
        CONSTRAINT CK_service_request_ServiceRequest_Status
            CHECK (Status IN ('OPEN', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
        CONSTRAINT CK_service_request_ServiceRequest_CompletedAt
            CHECK (CompletedAt IS NULL OR CompletedAt >= CreatedAt)
    );
END
GO

IF OBJECT_ID(N'escalation.Escalation', N'U') IS NULL
BEGIN
    CREATE TABLE escalation.Escalation
    (
        EscalationId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_escalation_Escalation PRIMARY KEY,
        CaseId       BIGINT        NOT NULL,
        EscalationLevel TINYINT    NOT NULL,
        Reason       NVARCHAR(400) NOT NULL,
        Owner        NVARCHAR(128) NOT NULL,
        EscalatedAt  DATETIME2(3)  NOT NULL
            CONSTRAINT DF_escalation_Escalation_EscalatedAt DEFAULT (SYSUTCDATETIME()),
        ResolvedAt   DATETIME2(3)  NULL,
        CONSTRAINT FK_escalation_Escalation_Case
            FOREIGN KEY (CaseId) REFERENCES support.SupportCase (CaseId),
        CONSTRAINT CK_escalation_Escalation_Level
            CHECK (EscalationLevel BETWEEN 1 AND 5),
        CONSTRAINT CK_escalation_Escalation_ResolvedAt
            CHECK (ResolvedAt IS NULL OR ResolvedAt >= EscalatedAt)
    );
END
GO

PRINT N'AFS_CustomerService tables created (or already existed).';
GO
