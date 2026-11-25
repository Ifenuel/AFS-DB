/* ============================================================================
   AFS-DBA-001
   P-01 Payment integrity laboratory — schema
   Database : AFS_Payments   (schema paylab — NOT a new database)
   Purpose  : reproduce dry posting, duplicate posting, lost-update concurrency
              and ambiguous outcomes against a double-entry ledger, then fix.

   All data is synthetic. The schema mirrors the shape of the portfolio's
   payment.Payment / account.AccountLedgerEntry tables without modifying them.
   ============================================================================ */
SET NOCOUNT ON;
USE AFS_Payments;
GO

IF SCHEMA_ID('paylab') IS NULL EXEC('CREATE SCHEMA paylab AUTHORIZATION dbo;');
GO

/* ---------- accounts ------------------------------------------------------ */
IF OBJECT_ID('paylab.Account') IS NULL
CREATE TABLE paylab.Account
(
    AccountId       bigint IDENTITY(1,1) NOT NULL,
    AccountNumber   char(12)             NOT NULL,
    CustomerName    nvarchar(80)         NOT NULL,
    CurrencyCode    char(3)              NOT NULL CONSTRAINT DF_paylab_Account_Currency DEFAULT ('NGN'),
    OpeningBalance  decimal(18,4)        NOT NULL,
    Balance         decimal(18,4)        NOT NULL,
    RowVersion      rowversion           NOT NULL,
    CONSTRAINT PK_paylab_Account PRIMARY KEY (AccountId),
    CONSTRAINT UQ_paylab_Account_Number UNIQUE (AccountNumber),
    CONSTRAINT CK_paylab_Account_Opening CHECK (OpeningBalance >= 0),
    CONSTRAINT CK_paylab_Account_Balance CHECK (Balance >= 0)
);
GO

/* ---------- payment intent and lifecycle ---------------------------------- */
IF OBJECT_ID('paylab.PaymentIntent') IS NULL
CREATE TABLE paylab.PaymentIntent
(
    PaymentId           bigint IDENTITY(1,1) NOT NULL,
    RequestId           uniqueidentifier     NOT NULL,
    IdempotencyKey      varchar(64)          NULL,
    DebitAccountId      bigint               NOT NULL,
    CreditAccountId     bigint               NOT NULL,
    Amount              decimal(18,4)        NOT NULL,
    Status              varchar(20)          NOT NULL CONSTRAINT DF_paylab_Intent_Status DEFAULT ('RECEIVED'),
    FailureCode         varchar(40)          NULL,
    CreatedAt           datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Intent_Created DEFAULT (SYSUTCDATETIME()),
    UpdatedAt           datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Intent_Updated DEFAULT (SYSUTCDATETIME()),
    RowVersion          rowversion           NOT NULL,
    CONSTRAINT PK_paylab_PaymentIntent PRIMARY KEY (PaymentId),
    CONSTRAINT FK_paylab_Intent_Debit  FOREIGN KEY (DebitAccountId)  REFERENCES paylab.Account(AccountId),
    CONSTRAINT FK_paylab_Intent_Credit FOREIGN KEY (CreditAccountId) REFERENCES paylab.Account(AccountId),
    CONSTRAINT CK_paylab_Intent_Amount CHECK (Amount > 0),
    CONSTRAINT CK_paylab_Intent_Distinct CHECK (DebitAccountId <> CreditAccountId),
    CONSTRAINT CK_paylab_Intent_Status CHECK (Status IN ('RECEIVED','PENDING','DEBITED','COMPLETED','FAILED','REVERSED'))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_paylab_Intent_Request')
    CREATE INDEX IX_paylab_Intent_Request ON paylab.PaymentIntent(RequestId);
GO

/* ---------- ledger -------------------------------------------------------- */
IF OBJECT_ID('paylab.LedgerEntry') IS NULL
CREATE TABLE paylab.LedgerEntry
(
    EntryId      bigint IDENTITY(1,1) NOT NULL,
    PaymentId    bigint               NULL,
    TransferRef  uniqueidentifier     NOT NULL,
    AccountId    bigint               NOT NULL,
    Direction    char(1)              NOT NULL,
    Amount       decimal(18,4)        NOT NULL,
    BalanceAfter decimal(18,4)        NOT NULL,
    OccurredAt   datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Ledger_At DEFAULT (SYSUTCDATETIME()),
    Note         nvarchar(120)        NULL,
    CONSTRAINT PK_paylab_LedgerEntry PRIMARY KEY (EntryId),
    CONSTRAINT FK_paylab_Ledger_Payment FOREIGN KEY (PaymentId) REFERENCES paylab.PaymentIntent(PaymentId),
    CONSTRAINT FK_paylab_Ledger_Account FOREIGN KEY (AccountId) REFERENCES paylab.Account(AccountId),
    CONSTRAINT CK_paylab_Ledger_Direction CHECK (Direction IN ('D','C')),
    CONSTRAINT CK_paylab_Ledger_Amount CHECK (Amount > 0)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_paylab_Ledger_Payment')
    CREATE INDEX IX_paylab_Ledger_Payment ON paylab.LedgerEntry(PaymentId, Direction) INCLUDE (Amount);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_paylab_Ledger_Account')
    CREATE INDEX IX_paylab_Ledger_Account ON paylab.LedgerEntry(AccountId, OccurredAt);
GO

/* ---------- events, outbox, inbox ---------------------------------------- */
IF OBJECT_ID('paylab.PaymentEvent') IS NULL
CREATE TABLE paylab.PaymentEvent
(
    EventId    bigint IDENTITY(1,1) NOT NULL,
    PaymentId  bigint               NOT NULL,
    EventType  varchar(30)          NOT NULL,
    Detail     nvarchar(300)        NULL,
    CreatedAt  datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Event_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_paylab_PaymentEvent PRIMARY KEY (EventId),
    CONSTRAINT FK_paylab_Event_Payment FOREIGN KEY (PaymentId) REFERENCES paylab.PaymentIntent(PaymentId)
);
GO

IF OBJECT_ID('paylab.Outbox') IS NULL
CREATE TABLE paylab.Outbox
(
    OutboxId   bigint IDENTITY(1,1) NOT NULL,
    PaymentId  bigint               NOT NULL,
    EventType  varchar(30)          NOT NULL,
    Payload    nvarchar(400)        NOT NULL,
    PublishedAt datetime2(7)        NULL,
    CreatedAt  datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Outbox_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_paylab_Outbox PRIMARY KEY (OutboxId),
    CONSTRAINT FK_paylab_Outbox_Payment FOREIGN KEY (PaymentId) REFERENCES paylab.PaymentIntent(PaymentId)
);
GO

IF OBJECT_ID('paylab.Inbox') IS NULL
CREATE TABLE paylab.Inbox
(
    MessageId   uniqueidentifier NOT NULL,
    PaymentId   bigint           NULL,
    ProcessedAt datetime2(7)     NOT NULL CONSTRAINT DF_paylab_Inbox_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_paylab_Inbox PRIMARY KEY (MessageId)
);
GO

/* ---------- reconciliation, exceptions, faults --------------------------- */
IF OBJECT_ID('paylab.ReconRun') IS NULL
CREATE TABLE paylab.ReconRun
(
    RunId           bigint IDENTITY(1,1) NOT NULL,
    Mode            varchar(10)          NOT NULL,
    StartedAt       datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Recon_Start DEFAULT (SYSUTCDATETIME()),
    FinishedAt      datetime2(7)         NULL,
    PaymentsChecked int                  NOT NULL CONSTRAINT DF_paylab_Recon_Checked DEFAULT (0),
    BreakCount      int                  NOT NULL CONSTRAINT DF_paylab_Recon_Breaks DEFAULT (0),
    CONSTRAINT PK_paylab_ReconRun PRIMARY KEY (RunId)
);
GO

IF OBJECT_ID('paylab.ReconBreak') IS NULL
CREATE TABLE paylab.ReconBreak
(
    BreakId    bigint IDENTITY(1,1) NOT NULL,
    RunId      bigint               NOT NULL,
    BreakType  varchar(30)          NOT NULL,
    PaymentId  bigint               NULL,
    AccountId  bigint               NULL,
    Detail     nvarchar(400)        NOT NULL,
    Amount     decimal(18,4)        NULL,
    CONSTRAINT PK_paylab_ReconBreak PRIMARY KEY (BreakId),
    CONSTRAINT FK_paylab_Break_Run FOREIGN KEY (RunId) REFERENCES paylab.ReconRun(RunId)
);
GO

IF OBJECT_ID('paylab.ExceptionQueue') IS NULL
CREATE TABLE paylab.ExceptionQueue
(
    ExceptionId bigint IDENTITY(1,1) NOT NULL,
    PaymentId   bigint               NULL,
    Reason      varchar(60)          NOT NULL,
    Detail      nvarchar(400)        NULL,
    Status      varchar(20)          NOT NULL CONSTRAINT DF_paylab_Exception_Status DEFAULT ('OPEN'),
    CreatedAt   datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Exception_At DEFAULT (SYSUTCDATETIME()),
    ResolvedAt  datetime2(7)         NULL,
    CONSTRAINT PK_paylab_ExceptionQueue PRIMARY KEY (ExceptionId),
    CONSTRAINT CK_paylab_Exception_Status CHECK (Status IN ('OPEN','RESOLVED','IGNORED'))
);
GO

IF OBJECT_ID('paylab.FaultLog') IS NULL
CREATE TABLE paylab.FaultLog
(
    FaultId    bigint IDENTITY(1,1) NOT NULL,
    Scenario   varchar(30)          NOT NULL,
    PaymentId  bigint               NULL,
    FaultType  varchar(40)          NOT NULL,
    Detail     nvarchar(300)        NULL,
    CreatedAt  datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Fault_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_paylab_FaultLog PRIMARY KEY (FaultId)
);
GO

IF OBJECT_ID('paylab.ScenarioRun') IS NULL
CREATE TABLE paylab.ScenarioRun
(
    RunId     bigint IDENTITY(1,1) NOT NULL,
    Scenario  varchar(40)          NOT NULL,
    Mode      varchar(10)          NOT NULL,
    StartedAt datetime2(7)         NOT NULL CONSTRAINT DF_paylab_Scenario_Start DEFAULT (SYSUTCDATETIME()),
    FinishedAt datetime2(7)        NULL,
    Notes     nvarchar(400)        NULL,
    CONSTRAINT PK_paylab_ScenarioRun PRIMARY KEY (RunId)
);
GO

/* ---------- deterministic seed ------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM paylab.Account)
BEGIN
    WITH n AS
    (
        SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
        FROM sys.all_objects
    )
    INSERT INTO paylab.Account (AccountNumber, CustomerName, CurrencyCode, OpeningBalance, Balance)
    SELECT 'PAYLAB' + RIGHT('000000' + CAST(i AS varchar(6)), 6),
           N'Synthetic Customer ' + CAST(i AS varchar(6)),
           'NGN',
           10000.0000,
           10000.0000
    FROM n;
END
GO

PRINT 'paylab schema ready';
SELECT COUNT(*) AS accounts, SUM(Balance) AS total_balance FROM paylab.Account;
GO
