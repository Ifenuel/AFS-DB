/*
  AFS-DBA-001
  Purpose: Create AFS_Reporting staging, reporting and warehouse tables.
  Safety: Idempotent at table level.
  Note: Reporting is SIMPLE recovery and may be rebuilt from source data.
*/

USE [AFS_Reporting];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'staging.StgTransaction', N'U') IS NULL
BEGIN
    CREATE TABLE staging.StgTransaction
    (
        StgTransactionId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_staging_StgTransaction PRIMARY KEY,
        TransferId       UNIQUEIDENTIFIER NOT NULL,
        AccountId        BIGINT        NOT NULL,
        EntryType        VARCHAR(6)    NOT NULL,
        Amount           DECIMAL(19,4) NOT NULL,
        BalanceAfter     DECIMAL(19,4) NOT NULL,
        CurrencyCode     CHAR(3)       NOT NULL,
        OccurredAt       DATETIME2(3)  NOT NULL,
        SourceDatabase   SYSNAME       NOT NULL
            CONSTRAINT DF_staging_StgTransaction_SourceDatabase DEFAULT ('AFS_CoreBanking'),
        LoadedAt         DATETIME2(3)  NOT NULL
            CONSTRAINT DF_staging_StgTransaction_LoadedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_staging_StgTransaction_EntryType
            CHECK (EntryType IN ('DEBIT', 'CREDIT')),
        CONSTRAINT CK_staging_StgTransaction_Amount
            CHECK (Amount <> 0)
    );
END
GO

IF OBJECT_ID(N'reporting.DailyAccountSummary', N'U') IS NULL
BEGIN
    CREATE TABLE reporting.DailyAccountSummary
    (
        SummaryDate     DATE          NOT NULL,
        AccountId       BIGINT        NOT NULL,
        OpeningBalance  DECIMAL(19,4) NOT NULL,
        ClosingBalance  DECIMAL(19,4) NOT NULL,
        DebitTotal      DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_reporting_DailyAccountSummary_DebitTotal DEFAULT (0),
        CreditTotal     DECIMAL(19,4) NOT NULL
            CONSTRAINT DF_reporting_DailyAccountSummary_CreditTotal DEFAULT (0),
        TransferCount   INT           NOT NULL
            CONSTRAINT DF_reporting_DailyAccountSummary_TransferCount DEFAULT (0),
        LoadedAt        DATETIME2(3)  NOT NULL
            CONSTRAINT DF_reporting_DailyAccountSummary_LoadedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_reporting_DailyAccountSummary PRIMARY KEY (SummaryDate, AccountId),
        CONSTRAINT CK_reporting_DailyAccountSummary_Count
            CHECK (TransferCount >= 0)
    );
END
GO

IF OBJECT_ID(N'reporting.TransferVolume', N'U') IS NULL
BEGIN
    CREATE TABLE reporting.TransferVolume
    (
        SummaryDate   DATE          NOT NULL,
        CurrencyCode  CHAR(3)       NOT NULL,
        TransferCount BIGINT        NOT NULL,
        TotalAmount   DECIMAL(19,4) NOT NULL,
        LoadedAt      DATETIME2(3)  NOT NULL
            CONSTRAINT DF_reporting_TransferVolume_LoadedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_reporting_TransferVolume PRIMARY KEY (SummaryDate, CurrencyCode),
        CONSTRAINT CK_reporting_TransferVolume_Count CHECK (TransferCount >= 0),
        CONSTRAINT CK_reporting_TransferVolume_Amount CHECK (TotalAmount >= 0)
    );
END
GO

IF OBJECT_ID(N'warehouse.DimDate', N'U') IS NULL
BEGIN
    CREATE TABLE warehouse.DimDate
    (
        DateKey       INT          NOT NULL
            CONSTRAINT PK_warehouse_DimDate PRIMARY KEY,
        FullDate      DATE         NOT NULL
            CONSTRAINT UQ_warehouse_DimDate_FullDate UNIQUE,
        YearNumber    SMALLINT     NOT NULL,
        QuarterNumber TINYINT      NOT NULL,
        MonthNumber   TINYINT      NOT NULL,
        DayNumber     TINYINT      NOT NULL,
        IsBusinessDay BIT          NOT NULL,
        CONSTRAINT CK_warehouse_DimDate_Quarter CHECK (QuarterNumber BETWEEN 1 AND 4),
        CONSTRAINT CK_warehouse_DimDate_Month CHECK (MonthNumber BETWEEN 1 AND 12),
        CONSTRAINT CK_warehouse_DimDate_Day CHECK (DayNumber BETWEEN 1 AND 31)
    );
END
GO

IF OBJECT_ID(N'warehouse.DimCustomer', N'U') IS NULL
BEGIN
    CREATE TABLE warehouse.DimCustomer
    (
        CustomerKey    BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_warehouse_DimCustomer PRIMARY KEY,
        CustomerId     BIGINT        NOT NULL,
        CustomerNumber CHAR(10)      NOT NULL,
        RiskRating     VARCHAR(10)   NOT NULL,
        CustomerStatus VARCHAR(20)   NOT NULL,
        IsCurrent      BIT           NOT NULL
            CONSTRAINT DF_warehouse_DimCustomer_IsCurrent DEFAULT (1),
        ValidFrom      DATETIME2(3)  NOT NULL
            CONSTRAINT DF_warehouse_DimCustomer_ValidFrom DEFAULT (SYSUTCDATETIME()),
        ValidTo        DATETIME2(3)  NULL,
        CONSTRAINT CK_warehouse_DimCustomer_ValidTo
            CHECK (ValidTo IS NULL OR ValidTo >= ValidFrom)
    );
END
GO

IF OBJECT_ID(N'warehouse.DimAccount', N'U') IS NULL
BEGIN
    CREATE TABLE warehouse.DimAccount
    (
        AccountKey    BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_warehouse_DimAccount PRIMARY KEY,
        AccountId     BIGINT        NOT NULL,
        AccountNumber CHAR(12)      NOT NULL,
        AccountType   VARCHAR(20)   NOT NULL,
        CurrencyCode  CHAR(3)       NOT NULL,
        CustomerId    BIGINT        NOT NULL,
        IsCurrent     BIT           NOT NULL
            CONSTRAINT DF_warehouse_DimAccount_IsCurrent DEFAULT (1),
        ValidFrom     DATETIME2(3)  NOT NULL
            CONSTRAINT DF_warehouse_DimAccount_ValidFrom DEFAULT (SYSUTCDATETIME()),
        ValidTo       DATETIME2(3)  NULL,
        CONSTRAINT CK_warehouse_DimAccount_ValidTo
            CHECK (ValidTo IS NULL OR ValidTo >= ValidFrom)
    );
END
GO

IF OBJECT_ID(N'warehouse.FactTransaction', N'U') IS NULL
BEGIN
    CREATE TABLE warehouse.FactTransaction
    (
        FactTransactionId BIGINT        IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_warehouse_FactTransaction PRIMARY KEY,
        DateKey           INT           NOT NULL,
        AccountKey        BIGINT        NOT NULL,
        TransferId        UNIQUEIDENTIFIER NOT NULL,
        EntryType         VARCHAR(6)    NOT NULL,
        Amount            DECIMAL(19,4) NOT NULL,
        BalanceAfter      DECIMAL(19,4) NOT NULL,
        CurrencyCode      CHAR(3)       NOT NULL,
        OccurredAt        DATETIME2(3)  NOT NULL,
        CONSTRAINT FK_warehouse_FactTransaction_Date
            FOREIGN KEY (DateKey) REFERENCES warehouse.DimDate (DateKey),
        CONSTRAINT FK_warehouse_FactTransaction_Account
            FOREIGN KEY (AccountKey) REFERENCES warehouse.DimAccount (AccountKey),
        CONSTRAINT UQ_warehouse_FactTransaction_Transfer_Account_Entry
            UNIQUE (TransferId, AccountKey, EntryType),
        CONSTRAINT CK_warehouse_FactTransaction_EntryType
            CHECK (EntryType IN ('DEBIT', 'CREDIT')),
        CONSTRAINT CK_warehouse_FactTransaction_Amount
            CHECK (Amount <> 0)
    );
END
GO

PRINT N'AFS_Reporting tables created (or already existed).';
GO
