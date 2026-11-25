/*
  AFS-DBA-001
  Purpose: Create AFS_CoreBanking tables and constraints.
  Safety: Idempotent at table level. Existing tables are not altered.
  Prerequisites: AFS_CoreBanking and schemas.
  Run as: AFS_DBA.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------------
-- reference
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'reference.Country', N'U') IS NULL
BEGIN
    CREATE TABLE reference.Country
    (
        CountryCode   CHAR(2)       NOT NULL
            CONSTRAINT PK_reference_Country PRIMARY KEY,
        CountryName   NVARCHAR(100) NOT NULL,
        IsActive      BIT           NOT NULL
            CONSTRAINT DF_reference_Country_IsActive DEFAULT (1),
        CONSTRAINT CK_reference_Country_Code CHECK (LEN(CountryCode) = 2)
    );
END
GO

IF OBJECT_ID(N'reference.Currency', N'U') IS NULL
BEGIN
    CREATE TABLE reference.Currency
    (
        CurrencyCode  CHAR(3)       NOT NULL
            CONSTRAINT PK_reference_Currency PRIMARY KEY,
        CurrencyName  NVARCHAR(100) NOT NULL,
        MinorUnit     TINYINT       NOT NULL
            CONSTRAINT DF_reference_Currency_MinorUnit DEFAULT (2),
        IsActive      BIT           NOT NULL
            CONSTRAINT DF_reference_Currency_IsActive DEFAULT (1),
        CONSTRAINT CK_reference_Currency_Code CHECK (LEN(CurrencyCode) = 3),
        CONSTRAINT CK_reference_Currency_MinorUnit CHECK (MinorUnit BETWEEN 0 AND 4)
    );
END
GO

IF OBJECT_ID(N'reference.AccountType', N'U') IS NULL
BEGIN
    CREATE TABLE reference.AccountType
    (
        AccountTypeId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_reference_AccountType PRIMARY KEY,
        TypeCode      VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_reference_AccountType_TypeCode UNIQUE,
        TypeName      NVARCHAR(100) NOT NULL,
        IsActive      BIT           NOT NULL
            CONSTRAINT DF_reference_AccountType_IsActive DEFAULT (1)
    );
END
GO

IF OBJECT_ID(N'reference.AccountStatus', N'U') IS NULL
BEGIN
    CREATE TABLE reference.AccountStatus
    (
        AccountStatusId INT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_reference_AccountStatus PRIMARY KEY,
        StatusCode      VARCHAR(20)   NOT NULL
            CONSTRAINT UQ_reference_AccountStatus_StatusCode UNIQUE,
        StatusName      NVARCHAR(100) NOT NULL,
        AllowsTransfers BIT           NOT NULL
            CONSTRAINT DF_reference_AccountStatus_AllowsTransfers DEFAULT (0),
        IsActive        BIT           NOT NULL
            CONSTRAINT DF_reference_AccountStatus_IsActive DEFAULT (1)
    );
END
GO

-- ---------------------------------------------------------------------------
-- customer
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'customer.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE customer.Customer
    (
        CustomerId      BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_customer_Customer PRIMARY KEY,
        CustomerNumber  CHAR(10)      NOT NULL
            CONSTRAINT UQ_customer_Customer_CustomerNumber UNIQUE,
        FirstName       NVARCHAR(100) NOT NULL,
        LastName        NVARCHAR(100) NOT NULL,
        DateOfBirth     DATE          NULL,
        Email           NVARCHAR(254) NULL,
        Phone           NVARCHAR(30)  NULL,
        CustomerStatus  VARCHAR(20)   NOT NULL
            CONSTRAINT DF_customer_Customer_Status DEFAULT ('ACTIVE'),
        RiskRating      VARCHAR(10)   NOT NULL
            CONSTRAINT DF_customer_Customer_RiskRating DEFAULT ('LOW'),
        CreatedAt       DATETIME2(3)  NOT NULL
            CONSTRAINT DF_customer_Customer_CreatedAt DEFAULT (SYSUTCDATETIME()),
        UpdatedAt       DATETIME2(3)  NOT NULL
            CONSTRAINT DF_customer_Customer_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        RowVersion      ROWVERSION    NOT NULL,
        CONSTRAINT CK_customer_Customer_Number
            CHECK (CustomerNumber LIKE 'C[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
        CONSTRAINT CK_customer_Customer_Status
            CHECK (CustomerStatus IN ('ACTIVE', 'DORMANT', 'CLOSED')),
        CONSTRAINT CK_customer_Customer_Risk
            CHECK (RiskRating IN ('LOW', 'MEDIUM', 'HIGH')),
        CONSTRAINT CK_customer_Customer_Dob
            CHECK (DateOfBirth IS NULL OR DateOfBirth >= '1900-01-01')
    );
END
GO

IF OBJECT_ID(N'customer.CustomerContact', N'U') IS NULL
BEGIN
    CREATE TABLE customer.CustomerContact
    (
        ContactId     BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_customer_CustomerContact PRIMARY KEY,
        CustomerId    BIGINT        NOT NULL,
        ContactType   VARCHAR(20)   NOT NULL,
        ContactValue  NVARCHAR(254) NOT NULL,
        IsPrimary     BIT           NOT NULL
            CONSTRAINT DF_customer_CustomerContact_IsPrimary DEFAULT (0),
        CreatedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_customer_CustomerContact_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_customer_CustomerContact_Customer
            FOREIGN KEY (CustomerId) REFERENCES customer.Customer (CustomerId),
        CONSTRAINT CK_customer_CustomerContact_Type
            CHECK (ContactType IN ('EMAIL', 'PHONE', 'MOBILE')),
        CONSTRAINT CK_customer_CustomerContact_Value
            CHECK (LEN(LTRIM(RTRIM(ContactValue))) > 0)
    );
END
GO

IF OBJECT_ID(N'customer.CustomerAddress', N'U') IS NULL
BEGIN
    CREATE TABLE customer.CustomerAddress
    (
        AddressId     BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_customer_CustomerAddress PRIMARY KEY,
        CustomerId    BIGINT        NOT NULL,
        AddressType   VARCHAR(20)   NOT NULL,
        Line1         NVARCHAR(200) NOT NULL,
        Line2         NVARCHAR(200) NULL,
        City          NVARCHAR(100) NOT NULL,
        Region        NVARCHAR(100) NULL,
        PostalCode    NVARCHAR(20)  NULL,
        CountryCode   CHAR(2)       NOT NULL,
        IsPrimary     BIT           NOT NULL
            CONSTRAINT DF_customer_CustomerAddress_IsPrimary DEFAULT (0),
        CreatedAt     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_customer_CustomerAddress_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_customer_CustomerAddress_Customer
            FOREIGN KEY (CustomerId) REFERENCES customer.Customer (CustomerId),
        CONSTRAINT FK_customer_CustomerAddress_Country
            FOREIGN KEY (CountryCode) REFERENCES reference.Country (CountryCode),
        CONSTRAINT CK_customer_CustomerAddress_Type
            CHECK (AddressType IN ('HOME', 'WORK', 'MAILING')),
        CONSTRAINT CK_customer_CustomerAddress_Line1
            CHECK (LEN(LTRIM(RTRIM(Line1))) > 0)
    );
END
GO

-- ---------------------------------------------------------------------------
-- account
-- ---------------------------------------------------------------------------
IF OBJECT_ID(N'account.Account', N'U') IS NULL
BEGIN
    CREATE TABLE account.Account
    (
        AccountId          BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_account_Account PRIMARY KEY,
        AccountNumber      CHAR(12)      NOT NULL
            CONSTRAINT UQ_account_Account_AccountNumber UNIQUE,
        CustomerId         BIGINT        NOT NULL,
        AccountTypeId      INT           NOT NULL,
        AccountStatusId    INT           NOT NULL,
        CurrencyCode       CHAR(3)       NOT NULL,
        Balance            DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_account_Account_Balance DEFAULT (0),
        OpeningBalance     DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_account_Account_OpeningBalance DEFAULT (0),
        OverdraftLimit     DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_account_Account_OverdraftLimit DEFAULT (0),
        PerTransferLimit   DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_account_Account_PerTransferLimit DEFAULT (10000),
        DailyTransferLimit DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_account_Account_DailyTransferLimit DEFAULT (50000),
        OpenedAt           DATETIME2(3)  NOT NULL
            CONSTRAINT DF_account_Account_OpenedAt DEFAULT (SYSUTCDATETIME()),
        ClosedAt           DATETIME2(3)  NULL,
        UpdatedAt          DATETIME2(3)  NOT NULL
            CONSTRAINT DF_account_Account_UpdatedAt DEFAULT (SYSUTCDATETIME()),
        RowVersion         ROWVERSION    NOT NULL,
        CONSTRAINT FK_account_Account_Customer
            FOREIGN KEY (CustomerId) REFERENCES customer.Customer (CustomerId),
        CONSTRAINT FK_account_Account_AccountType
            FOREIGN KEY (AccountTypeId) REFERENCES reference.AccountType (AccountTypeId),
        CONSTRAINT FK_account_Account_AccountStatus
            FOREIGN KEY (AccountStatusId) REFERENCES reference.AccountStatus (AccountStatusId),
        CONSTRAINT FK_account_Account_Currency
            FOREIGN KEY (CurrencyCode) REFERENCES reference.Currency (CurrencyCode),
        CONSTRAINT CK_account_Account_Number
            CHECK (AccountNumber LIKE 'ACC[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
        CONSTRAINT CK_account_Account_BalanceWithinOverdraft
            CHECK (Balance >= -OverdraftLimit),
        CONSTRAINT CK_account_Account_OverdraftLimit
            CHECK (OverdraftLimit >= 0),
        CONSTRAINT CK_account_Account_PerTransferLimit
            CHECK (PerTransferLimit > 0),
        CONSTRAINT CK_account_Account_DailyLimit
            CHECK (DailyTransferLimit >= PerTransferLimit),
        CONSTRAINT CK_account_Account_ClosedAt
            CHECK (ClosedAt IS NULL OR ClosedAt >= OpenedAt)
    );
END
GO

IF OBJECT_ID(N'account.Transfer', N'U') IS NULL
BEGIN
    CREATE TABLE account.Transfer
    (
        TransferId     UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT PK_account_Transfer PRIMARY KEY,
        RequestId      UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT UQ_account_Transfer_RequestId UNIQUE,
        FromAccountId  BIGINT           NOT NULL,
        ToAccountId    BIGINT           NOT NULL,
        Amount         DECIMAL(19,4)    NOT NULL,
        CurrencyCode   CHAR(3)          NOT NULL,
        Status         VARCHAR(20)      NOT NULL
            CONSTRAINT DF_account_Transfer_Status DEFAULT ('COMPLETED'),
        Description    NVARCHAR(200)    NULL,
        CorrelationId  UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT DF_account_Transfer_CorrelationId DEFAULT (NEWID()),
        CreatedAt      DATETIME2(3)     NOT NULL
            CONSTRAINT DF_account_Transfer_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CompletedAt    DATETIME2(3)     NOT NULL
            CONSTRAINT DF_account_Transfer_CompletedAt DEFAULT (SYSUTCDATETIME()),
        RowVersion     ROWVERSION       NOT NULL,
        CONSTRAINT FK_account_Transfer_FromAccount
            FOREIGN KEY (FromAccountId) REFERENCES account.Account (AccountId),
        CONSTRAINT FK_account_Transfer_ToAccount
            FOREIGN KEY (ToAccountId) REFERENCES account.Account (AccountId),
        CONSTRAINT FK_account_Transfer_Currency
            FOREIGN KEY (CurrencyCode) REFERENCES reference.Currency (CurrencyCode),
        CONSTRAINT CK_account_Transfer_DifferentAccounts
            CHECK (FromAccountId <> ToAccountId),
        CONSTRAINT CK_account_Transfer_Amount
            CHECK (Amount > 0),
        CONSTRAINT CK_account_Transfer_Status
            CHECK (Status = 'COMPLETED'),
        CONSTRAINT CK_account_Transfer_CompletedAt
            CHECK (CompletedAt >= CreatedAt)
    );
END
GO

IF OBJECT_ID(N'account.TransferEvent', N'U') IS NULL
BEGIN
    CREATE TABLE account.TransferEvent
    (
        TransferEventId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_account_TransferEvent PRIMARY KEY,
        TransferId      UNIQUEIDENTIFIER NOT NULL,
        EventType       VARCHAR(30)   NOT NULL,
        EventData       NVARCHAR(MAX) NULL,
        Actor           NVARCHAR(128) NOT NULL
            CONSTRAINT DF_account_TransferEvent_Actor DEFAULT (SUSER_SNAME()),
        CreatedAt       DATETIME2(3)  NOT NULL
            CONSTRAINT DF_account_TransferEvent_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT FK_account_TransferEvent_Transfer
            FOREIGN KEY (TransferId) REFERENCES account.Transfer (TransferId),
        CONSTRAINT CK_account_TransferEvent_EventData
            CHECK (EventData IS NULL OR ISJSON(EventData) = 1)
    );
END
GO

IF OBJECT_ID(N'account.AccountLedgerEntry', N'U') IS NULL
BEGIN
    CREATE TABLE account.AccountLedgerEntry
    (
        LedgerEntryId  BIGINT           IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_account_AccountLedgerEntry PRIMARY KEY,
        TransferId     UNIQUEIDENTIFIER NOT NULL,
        AccountId      BIGINT           NOT NULL,
        EntryType      VARCHAR(6)       NOT NULL,
        Amount         DECIMAL(19,4)    NOT NULL,
        BalanceAfter   DECIMAL(19,4)    NOT NULL,
        CurrencyCode   CHAR(3)          NOT NULL,
        OccurredAt     DATETIME2(3)     NOT NULL
            CONSTRAINT DF_account_AccountLedgerEntry_OccurredAt DEFAULT (SYSUTCDATETIME()),
        Description    NVARCHAR(200)    NULL,
        CONSTRAINT FK_account_AccountLedgerEntry_Transfer
            FOREIGN KEY (TransferId) REFERENCES account.Transfer (TransferId),
        CONSTRAINT FK_account_AccountLedgerEntry_Account
            FOREIGN KEY (AccountId) REFERENCES account.Account (AccountId),
        CONSTRAINT FK_account_AccountLedgerEntry_Currency
            FOREIGN KEY (CurrencyCode) REFERENCES reference.Currency (CurrencyCode),
        CONSTRAINT CK_account_AccountLedgerEntry_EntryType
            CHECK (EntryType IN ('DEBIT', 'CREDIT')),
        CONSTRAINT CK_account_AccountLedgerEntry_Amount
            CHECK (Amount <> 0),
        CONSTRAINT UQ_account_AccountLedgerEntry_Transfer_EntryType
            UNIQUE (TransferId, EntryType),
        CONSTRAINT UQ_account_AccountLedgerEntry_Transfer_Account
            UNIQUE (TransferId, AccountId)
    );
END
GO

-- ---------------------------------------------------------------------------
-- audit
-- ---------------------------------------------------------------------------
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

PRINT N'AFS_CoreBanking tables created (or already existed).';
GO

SELECT s.name AS schema_name, t.name AS table_name, t.create_date
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name IN ('customer', 'account', 'reference', 'audit')
ORDER BY s.name, t.name;
GO
