/*
  AFS-DBA-001
  P-03 change and recovery laboratory — disposable target database.

  This database exists only for the drill. It is created from scratch, holds
  10,000 synthetic accounts, and is dropped at the end of the run so it never
  appears in the portfolio inventory.
*/
SET NOCOUNT ON;
USE master;
GO

IF DB_ID('AFS_Lab_Change') IS NOT NULL
BEGIN
    ALTER DATABASE AFS_Lab_Change SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AFS_Lab_Change;
END
GO

CREATE DATABASE AFS_Lab_Change;
GO

ALTER DATABASE AFS_Lab_Change SET RECOVERY FULL;
GO

USE AFS_Lab_Change;
GO

IF SCHEMA_ID('lab') IS NULL EXEC('CREATE SCHEMA lab AUTHORIZATION dbo;');
GO

CREATE TABLE lab.Account
(
    AccountId     int IDENTITY(1,1) NOT NULL,
    AccountNumber char(12)          NOT NULL,
    Balance       decimal(18,2)     NOT NULL,
    Tier          tinyint           NOT NULL,
    UpdatedAt     datetime2(7)      NOT NULL CONSTRAINT DF_lab_Account_Updated DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_lab_Account PRIMARY KEY (AccountId),
    CONSTRAINT UQ_lab_Account_Number UNIQUE (AccountNumber),
    CONSTRAINT CK_lab_Account_Balance CHECK (Balance >= 0)
);
GO

WITH n AS (SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO lab.Account (AccountNumber, Balance, Tier)
SELECT 'LAB' + RIGHT('000000000' + CAST(i AS varchar(9)), 9),
       CAST(1000 + (i % 500) AS decimal(18,2)),
       CAST(1 + (i % 3) AS tinyint)
FROM n;
GO

CREATE TABLE lab.ChangeLog
(
    ChangeId    int IDENTITY(1,1) NOT NULL,
    AppliedAt   datetime2(7)      NOT NULL CONSTRAINT DF_lab_ChangeLog_At DEFAULT (SYSUTCDATETIME()),
    Description nvarchar(200)     NOT NULL,
    RowsAffected int              NULL,
    Outcome     varchar(20)       NOT NULL,
    CONSTRAINT PK_lab_ChangeLog PRIMARY KEY (ChangeId)
);
GO

SELECT COUNT(*) AS accounts, SUM(Balance) AS total_balance,
       CHECKSUM_AGG(BINARY_CHECKSUM(AccountId, Balance, Tier)) AS checksum
FROM lab.Account;
GO
