/*
  AFS-DBA-001
  Purpose: Exercise the transfer engine and assert financial invariants.
  Safety: Operates only on fixed synthetic test customer/accounts. It deletes
          prior test transfers and resets their balances. Do not run in a
          database containing real data.
  Prerequisites: Schema, reference data, transfer procedure.
  Run as: AFS_DBA.
  Note: Concurrency is covered separately by the two-session procedure; this
        script is single-session and does not claim to prove concurrency safety.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

CREATE TABLE #Results
(
    TestId VARCHAR(20) NOT NULL,
    TestName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(400) NOT NULL,
    Actual NVARCHAR(400) NOT NULL,
    Status VARCHAR(10) NOT NULL
);

DECLARE @TestCustomerNumber CHAR(10) = 'C999999999';
DECLARE @FromNumber CHAR(12) = 'ACC999999991';
DECLARE @ToNumber CHAR(12) = 'ACC999999992';
DECLARE @FrozenNumber CHAR(12) = 'ACC999999993';
DECLARE @CustomerId BIGINT;
DECLARE @FromAccountId BIGINT;
DECLARE @ToAccountId BIGINT;
DECLARE @FrozenAccountId BIGINT;
DECLARE @ActiveStatusId INT;
DECLARE @FrozenStatusId INT;
DECLARE @CheckingTypeId INT;

SELECT @ActiveStatusId = AccountStatusId FROM reference.AccountStatus WHERE StatusCode = 'ACTIVE';
SELECT @FrozenStatusId = AccountStatusId FROM reference.AccountStatus WHERE StatusCode = 'FROZEN';
SELECT @CheckingTypeId = AccountTypeId FROM reference.AccountType WHERE TypeCode = 'CHECKING';

IF @ActiveStatusId IS NULL OR @FrozenStatusId IS NULL OR @CheckingTypeId IS NULL
    THROW 59901, N'Required reference data is missing.', 1;

IF NOT EXISTS (SELECT 1 FROM customer.Customer WHERE CustomerNumber = @TestCustomerNumber)
BEGIN
    INSERT customer.Customer
        (CustomerNumber, FirstName, LastName, DateOfBirth, Email, Phone, CustomerStatus, RiskRating)
    VALUES
        (@TestCustomerNumber, N'Test', N'Customer', '1980-01-01',
         N'test.customer@example.invalid', N'+10000000000', 'ACTIVE', 'LOW');
END

SELECT @CustomerId = CustomerId FROM customer.Customer WHERE CustomerNumber = @TestCustomerNumber;

IF NOT EXISTS (SELECT 1 FROM account.Account WHERE AccountNumber = @FromNumber)
    INSERT account.Account
        (AccountNumber, CustomerId, AccountTypeId, AccountStatusId, CurrencyCode,
         Balance, OpeningBalance, OverdraftLimit, PerTransferLimit, DailyTransferLimit)
    VALUES
        (@FromNumber, @CustomerId, @CheckingTypeId, @ActiveStatusId, 'USD',
         1000, 1000, 0, 100000, 1000000);

IF NOT EXISTS (SELECT 1 FROM account.Account WHERE AccountNumber = @ToNumber)
    INSERT account.Account
        (AccountNumber, CustomerId, AccountTypeId, AccountStatusId, CurrencyCode,
         Balance, OpeningBalance, OverdraftLimit, PerTransferLimit, DailyTransferLimit)
    VALUES
        (@ToNumber, @CustomerId, @CheckingTypeId, @ActiveStatusId, 'USD',
         500, 500, 0, 100000, 1000000);

IF NOT EXISTS (SELECT 1 FROM account.Account WHERE AccountNumber = @FrozenNumber)
    INSERT account.Account
        (AccountNumber, CustomerId, AccountTypeId, AccountStatusId, CurrencyCode,
         Balance, OpeningBalance, OverdraftLimit, PerTransferLimit, DailyTransferLimit)
    VALUES
        (@FrozenNumber, @CustomerId, @CheckingTypeId, @FrozenStatusId, 'USD',
         1000, 1000, 0, 100000, 1000000);

SELECT @FromAccountId = AccountId FROM account.Account WHERE AccountNumber = @FromNumber;
SELECT @ToAccountId = AccountId FROM account.Account WHERE AccountNumber = @ToNumber;
SELECT @FrozenAccountId = AccountId FROM account.Account WHERE AccountNumber = @FrozenNumber;

-- Clean only the fixed test accounts so the script is repeatable.
DELETE l
FROM account.AccountLedgerEntry AS l
JOIN account.Transfer AS t ON t.TransferId = l.TransferId
WHERE t.FromAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId)
   OR t.ToAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId);

DELETE e
FROM account.TransferEvent AS e
JOIN account.Transfer AS t ON t.TransferId = e.TransferId
WHERE t.FromAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId)
   OR t.ToAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId);

DELETE FROM account.Transfer
WHERE FromAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId)
   OR ToAccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId);

UPDATE account.Account
SET Balance = CASE WHEN AccountId = @FromAccountId THEN 1000
                   WHEN AccountId = @ToAccountId THEN 500
                   ELSE 1000 END,
    OpeningBalance = CASE WHEN AccountId = @FromAccountId THEN 1000
                         WHEN AccountId = @ToAccountId THEN 500
                         ELSE 1000 END,
    AccountStatusId = CASE WHEN AccountId = @FrozenAccountId THEN @FrozenStatusId ELSE @ActiveStatusId END,
    PerTransferLimit = 100000,
    DailyTransferLimit = 1000000,
    UpdatedAt = SYSUTCDATETIME()
WHERE AccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId);

-- ---------------------------------------------------------------------------
-- T-TXN-001: successful transfer
-- ---------------------------------------------------------------------------
DECLARE @ReqSuccess UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @TransferId UNIQUEIDENTIFIER;
DECLARE @ResultCode VARCHAR(20);
DECLARE @ResultMessage NVARCHAR(400);
DECLARE @FromBalance DECIMAL(19,4);
DECLARE @ToBalance DECIMAL(19,4);
DECLARE @Count INT;

BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqSuccess,
        @FromAccountId = @FromAccountId,
        @ToAccountId = @ToAccountId,
        @Amount = 100,
        @CurrencyCode = 'USD',
        @Description = N'Test successful transfer',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    SELECT @FromBalance = Balance FROM account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM account.Account WHERE AccountId = @ToAccountId;

    INSERT #Results VALUES
        ('T-TXN-001', N'Successful transfer',
         N'COMPLETED; sender 900; recipient 600',
         CONCAT(@ResultCode, N'; sender ', @FromBalance, N'; recipient ', @ToBalance),
         CASE WHEN @ResultCode = 'COMPLETED' AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    INSERT #Results VALUES
        ('T-TXN-001', N'Successful transfer', N'COMPLETED; sender 900; recipient 600',
         CONCAT(N'Unexpected error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 'FAIL');
END CATCH;

-- ---------------------------------------------------------------------------
-- T-TXN-002: duplicate request must not post twice
-- ---------------------------------------------------------------------------
SET @ResultCode = NULL;
BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqSuccess,
        @FromAccountId = @FromAccountId,
        @ToAccountId = @ToAccountId,
        @Amount = 100,
        @CurrencyCode = 'USD',
        @Description = N'Duplicate retry',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    SELECT @FromBalance = Balance FROM account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM account.Account WHERE AccountId = @ToAccountId;
    SELECT @Count = COUNT(*) FROM account.Transfer WHERE RequestId = @ReqSuccess;

    INSERT #Results VALUES
        ('T-TXN-002', N'Duplicate request is idempotent',
         N'DUPLICATE; one transfer; balances 900/600',
         CONCAT(@ResultCode, N'; transfer count ', @Count, N'; balances ', @FromBalance, N'/', @ToBalance),
         CASE WHEN @ResultCode = 'DUPLICATE' AND @Count = 1
                   AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    INSERT #Results VALUES
        ('T-TXN-002', N'Duplicate request is idempotent',
         N'DUPLICATE; one transfer; balances 900/600',
         CONCAT(N'Unexpected error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 'FAIL');
END CATCH;

-- ---------------------------------------------------------------------------
-- T-TXN-003: insufficient funds
-- ---------------------------------------------------------------------------
DECLARE @ReqInsufficient UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqInsufficient,
        @FromAccountId = @FromAccountId,
        @ToAccountId = @ToAccountId,
        @Amount = 5000,
        @CurrencyCode = 'USD',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT;

    INSERT #Results VALUES
        ('T-TXN-003', N'Insufficient funds rejected',
         N'Error 51006; no transfer', CONCAT(N'Unexpected success: ', @ResultCode), 'FAIL');
END TRY
BEGIN CATCH
    SELECT @FromBalance = Balance FROM account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM account.Account WHERE AccountId = @ToAccountId;
    SELECT @Count = COUNT(*) FROM account.Transfer WHERE RequestId = @ReqInsufficient;

    INSERT #Results VALUES
        ('T-TXN-003', N'Insufficient funds rejected',
         N'Error 51006; no transfer; balances 900/600',
         CONCAT(N'Error ', ERROR_NUMBER(), N'; transfers ', @Count, N'; balances ', @FromBalance, N'/', @ToBalance),
         CASE WHEN ERROR_NUMBER() = 51006 AND @Count = 0
                   AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- ---------------------------------------------------------------------------
-- T-TXN-004: inactive account
-- ---------------------------------------------------------------------------
DECLARE @ReqInactive UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
UPDATE account.Account SET AccountStatusId = @FrozenStatusId WHERE AccountId = @FrozenAccountId;

BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqInactive,
        @FromAccountId = @FrozenAccountId,
        @ToAccountId = @ToAccountId,
        @Amount = 10,
        @CurrencyCode = 'USD',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT;

    INSERT #Results VALUES
        ('T-TXN-004', N'Inactive account rejected',
         N'Error 51002; no transfer', CONCAT(N'Unexpected success: ', @ResultCode), 'FAIL');
END TRY
BEGIN CATCH
    SELECT @Count = COUNT(*) FROM account.Transfer WHERE RequestId = @ReqInactive;
    INSERT #Results VALUES
        ('T-TXN-004', N'Inactive account rejected',
         N'Error 51002; no transfer',
         CONCAT(N'Error ', ERROR_NUMBER(), N'; transfers ', @Count),
         CASE WHEN ERROR_NUMBER() = 51002 AND @Count = 0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

UPDATE account.Account SET AccountStatusId = @ActiveStatusId WHERE AccountId = @FrozenAccountId;

-- ---------------------------------------------------------------------------
-- T-TXN-005: invalid recipient
-- ---------------------------------------------------------------------------
DECLARE @ReqInvalid UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444444';
BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqInvalid,
        @FromAccountId = @FromAccountId,
        @ToAccountId = 999999999,
        @Amount = 10,
        @CurrencyCode = 'USD',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT;

    INSERT #Results VALUES
        ('T-TXN-005', N'Invalid recipient rejected',
         N'Error 51001; no transfer', CONCAT(N'Unexpected success: ', @ResultCode), 'FAIL');
END TRY
BEGIN CATCH
    SELECT @Count = COUNT(*) FROM account.Transfer WHERE RequestId = @ReqInvalid;
    INSERT #Results VALUES
        ('T-TXN-005', N'Invalid recipient rejected',
         N'Error 51001; no transfer',
         CONCAT(N'Error ', ERROR_NUMBER(), N'; transfers ', @Count),
         CASE WHEN ERROR_NUMBER() = 51001 AND @Count = 0 THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

-- ---------------------------------------------------------------------------
-- T-TXN-006: forced failure after debit must roll back every change
-- ---------------------------------------------------------------------------
DECLARE @ReqRollback UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555555';
DROP TRIGGER IF EXISTS account.trg_TestForceRollback;
EXEC(N'
CREATE TRIGGER account.trg_TestForceRollback
ON account.AccountLedgerEntry
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted WHERE Description = N''FORCE_ROLLBACK'')
        THROW 59999, N''Forced test failure after posting.'', 1;
END;
');

-- Clear the output variable retained from earlier tests. Passing a stale
-- TransferId would look like a caller-supplied key and fail on the primary key
-- before the rollback trigger could be exercised.
SET @TransferId = NULL;
SET @ResultCode = NULL;

BEGIN TRY
    EXEC account.usp_ExecuteTransfer
        @RequestId = @ReqRollback,
        @FromAccountId = @FromAccountId,
        @ToAccountId = @ToAccountId,
        @Amount = 50,
        @CurrencyCode = 'USD',
        @Description = N'FORCE_ROLLBACK',
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT;

    INSERT #Results VALUES
        ('T-TXN-006', N'Forced failure rolls back',
         N'Error 59999; balances unchanged; no transfer', N'Unexpected success', 'FAIL');
END TRY
BEGIN CATCH
    SELECT @FromBalance = Balance FROM account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM account.Account WHERE AccountId = @ToAccountId;
    SELECT @Count = COUNT(*) FROM account.Transfer WHERE RequestId = @ReqRollback;

    INSERT #Results VALUES
        ('T-TXN-006', N'Forced failure rolls back',
         N'Error 59999; balances 900/600; no transfer',
         CONCAT(N'Error ', ERROR_NUMBER(), N'; balances ', @FromBalance, N'/', @ToBalance, N'; transfers ', @Count),
         CASE WHEN ERROR_NUMBER() = 59999 AND @FromBalance = 900 AND @ToBalance = 600 AND @Count = 0
              THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

DROP TRIGGER IF EXISTS account.trg_TestForceRollback;

-- ---------------------------------------------------------------------------
-- T-TXN-007: ledger reconciliation
-- ---------------------------------------------------------------------------
DECLARE @Mismatches INT;
SELECT @Mismatches = COUNT(*)
FROM
(
    SELECT a.AccountId, a.Balance, a.OpeningBalance,
           ISNULL(SUM(l.Amount), 0) AS LedgerBalance
    FROM account.Account AS a
    LEFT JOIN account.AccountLedgerEntry AS l ON l.AccountId = a.AccountId
    WHERE a.AccountId IN (@FromAccountId, @ToAccountId, @FrozenAccountId)
    GROUP BY a.AccountId, a.Balance, a.OpeningBalance
    HAVING ABS(a.Balance - (a.OpeningBalance + ISNULL(SUM(l.Amount), 0))) > 0.0001
) AS x;

INSERT #Results VALUES
    ('T-TXN-007', N'Balance equals OpeningBalance + ledger sum for test accounts',
     N'0 mismatches', CONCAT(@Mismatches, N' mismatches'),
     CASE WHEN @Mismatches = 0 THEN 'PASS' ELSE 'FAIL' END);

-- ---------------------------------------------------------------------------
-- T-TXN-008: failure is audited
-- ---------------------------------------------------------------------------
DECLARE @FailureAuditCount INT;
SELECT @FailureAuditCount = COUNT(*)
FROM audit.AuditEvent
WHERE EventType = 'TRANSFER_FAILED'
  AND EntityId = CONVERT(NVARCHAR(36), @ReqInsufficient);

INSERT #Results VALUES
    ('T-TXN-008', N'Failed transfer is audited',
     N'At least 1 failure audit event', CONCAT(@FailureAuditCount, N' event(s)'),
     CASE WHEN @FailureAuditCount >= 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT TestId, TestName, Expected, Actual, Status FROM #Results ORDER BY TestId;
SELECT COUNT(*) AS TotalTests,
       SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS Passed,
       SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS Failed
FROM #Results;

IF EXISTS (SELECT 1 FROM #Results WHERE Status = 'FAIL')
    THROW 59900, N'One or more transfer tests failed.', 1;

PRINT N'ALL TRANSFER TESTS PASSED.';
GO
