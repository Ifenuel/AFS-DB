/*
  AFS-DBA-001
  Purpose: Exercise the payment orchestration and its idempotency/failure paths.
  Safety: Fixed synthetic test accounts only. Deletes prior test payments and
          transfers for those accounts and resets their balances.
  Prerequisites: Core and Payments schemas/procedures, reference data.
  Run as: AFS_DBA.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
GO

CREATE TABLE #Results
(
    TestId VARCHAR(20) NOT NULL,
    TestName NVARCHAR(200) NOT NULL,
    Expected NVARCHAR(400) NOT NULL,
    Actual NVARCHAR(400) NOT NULL,
    Status VARCHAR(10) NOT NULL
);

DECLARE @TestCustomerNumber CHAR(10) = 'C999999998';
DECLARE @FromNumber CHAR(12) = 'ACC999999981';
DECLARE @ToNumber CHAR(12) = 'ACC999999982';
DECLARE @CustomerId BIGINT;
DECLARE @FromAccountId BIGINT;
DECLARE @ToAccountId BIGINT;
DECLARE @ActiveStatusId INT;
DECLARE @CheckingTypeId INT;

SELECT @ActiveStatusId = AccountStatusId FROM reference.AccountStatus WHERE StatusCode = 'ACTIVE';
SELECT @CheckingTypeId = AccountTypeId FROM reference.AccountType WHERE TypeCode = 'CHECKING';

IF NOT EXISTS (SELECT 1 FROM customer.Customer WHERE CustomerNumber = @TestCustomerNumber)
    INSERT customer.Customer
        (CustomerNumber, FirstName, LastName, DateOfBirth, Email, Phone, CustomerStatus, RiskRating)
    VALUES
        (@TestCustomerNumber, N'Payment', N'Test', '1985-01-01',
         N'payment.test@example.invalid', N'+10000000001', 'ACTIVE', 'LOW');

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

SELECT @FromAccountId = AccountId FROM account.Account WHERE AccountNumber = @FromNumber;
SELECT @ToAccountId = AccountId FROM account.Account WHERE AccountNumber = @ToNumber;

DELETE l
FROM account.AccountLedgerEntry AS l
JOIN account.Transfer AS t ON t.TransferId = l.TransferId
WHERE t.FromAccountId IN (@FromAccountId, @ToAccountId)
   OR t.ToAccountId IN (@FromAccountId, @ToAccountId);

DELETE e
FROM account.TransferEvent AS e
JOIN account.Transfer AS t ON t.TransferId = e.TransferId
WHERE t.FromAccountId IN (@FromAccountId, @ToAccountId)
   OR t.ToAccountId IN (@FromAccountId, @ToAccountId);

DELETE FROM account.Transfer
WHERE FromAccountId IN (@FromAccountId, @ToAccountId)
   OR ToAccountId IN (@FromAccountId, @ToAccountId);

UPDATE account.Account
SET Balance = CASE WHEN AccountId = @FromAccountId THEN 1000 ELSE 500 END,
    OpeningBalance = CASE WHEN AccountId = @FromAccountId THEN 1000 ELSE 500 END,
    AccountStatusId = @ActiveStatusId,
    PerTransferLimit = 100000,
    DailyTransferLimit = 1000000,
    UpdatedAt = SYSUTCDATETIME()
WHERE AccountId IN (@FromAccountId, @ToAccountId);

USE [AFS_Payments];
GO

-- Clean up prior test payments that reference the fixed test accounts.
DELETE e
FROM payment.PaymentEvent AS e
JOIN payment.Payment AS p ON p.PaymentId = e.PaymentId
WHERE p.RequestId IN
(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
);

DELETE FROM payment.Payment
WHERE RequestId IN
(
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
);
GO

DECLARE @ReqPayment UNIQUEIDENTIFIER = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
DECLARE @PaymentId BIGINT;
DECLARE @PaymentReference VARCHAR(24);
DECLARE @TransferId UNIQUEIDENTIFIER;
DECLARE @ResultCode VARCHAR(20);
DECLARE @ResultMessage NVARCHAR(400);
DECLARE @FromAccountId BIGINT = (SELECT AccountId FROM AFS_CoreBanking.account.Account WHERE AccountNumber = 'ACC999999981');
DECLARE @ToAccountId BIGINT = (SELECT AccountId FROM AFS_CoreBanking.account.Account WHERE AccountNumber = 'ACC999999982');
DECLARE @FromBalance DECIMAL(19,4);
DECLARE @ToBalance DECIMAL(19,4);
DECLARE @PaymentCount INT;
DECLARE @PaymentStatus VARCHAR(20);

BEGIN TRY
    EXEC payment.usp_CreatePayment
        @RequestId = @ReqPayment,
        @DebitAccountId = @FromAccountId,
        @BeneficiaryAccountId = @ToAccountId,
        @BeneficiaryName = N'Test Beneficiary',
        @BeneficiaryAccountNumber = N'ACC999999982',
        @Amount = 100,
        @CurrencyCode = 'USD',
        @PaymentMethodCode = 'INTERNAL',
        @PaymentId = @PaymentId OUTPUT,
        @PaymentReference = @PaymentReference OUTPUT,
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    SELECT @FromBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @ToAccountId;
    SELECT @PaymentCount = COUNT(*) FROM payment.Payment WHERE RequestId = @ReqPayment;

    INSERT #Results VALUES
        ('T-PAY-001', N'Payment completes and posts once',
         N'COMPLETED; one payment; balances 900/600',
         CONCAT(@ResultCode, N'; payments ', @PaymentCount, N'; balances ', @FromBalance, N'/', @ToBalance),
         CASE WHEN @ResultCode = 'COMPLETED' AND @PaymentCount = 1
                   AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    INSERT #Results VALUES
        ('T-PAY-001', N'Payment completes and posts once', N'COMPLETED; one payment; balances 900/600',
         CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 'FAIL');
END CATCH;

-- Duplicate request: no second payment, no second transfer.
SET @ResultCode = NULL;
BEGIN TRY
    EXEC payment.usp_CreatePayment
        @RequestId = @ReqPayment,
        @DebitAccountId = @FromAccountId,
        @BeneficiaryAccountId = @ToAccountId,
        @BeneficiaryName = N'Test Beneficiary',
        @BeneficiaryAccountNumber = N'ACC999999982',
        @Amount = 100,
        @CurrencyCode = 'USD',
        @PaymentMethodCode = 'INTERNAL',
        @PaymentId = @PaymentId OUTPUT,
        @PaymentReference = @PaymentReference OUTPUT,
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    SELECT @FromBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @ToAccountId;
    SELECT @PaymentCount = COUNT(*) FROM payment.Payment WHERE RequestId = @ReqPayment;

    INSERT #Results VALUES
        ('T-PAY-002', N'Duplicate payment request is idempotent',
         N'COMPLETED/DUPLICATE; one payment; balances 900/600',
         CONCAT(@ResultCode, N'; payments ', @PaymentCount, N'; balances ', @FromBalance, N'/', @ToBalance),
         CASE WHEN @ResultCode IN ('COMPLETED', 'DUPLICATE') AND @PaymentCount = 1
                   AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END TRY
BEGIN CATCH
    INSERT #Results VALUES
        ('T-PAY-002', N'Duplicate payment request is idempotent',
         N'COMPLETED/DUPLICATE; one payment; balances 900/600',
         CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()), 'FAIL');
END CATCH;

-- Insufficient funds: payment is marked failed and no transfer is created.
DECLARE @ReqFail UNIQUEIDENTIFIER = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
BEGIN TRY
    EXEC payment.usp_CreatePayment
        @RequestId = @ReqFail,
        @DebitAccountId = @FromAccountId,
        @BeneficiaryAccountId = @ToAccountId,
        @BeneficiaryName = N'Test Beneficiary',
        @BeneficiaryAccountNumber = N'ACC999999982',
        @Amount = 5000,
        @CurrencyCode = 'USD',
        @PaymentMethodCode = 'INTERNAL',
        @PaymentId = @PaymentId OUTPUT,
        @PaymentReference = @PaymentReference OUTPUT,
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    INSERT #Results VALUES
        ('T-PAY-003', N'Insufficient funds fails payment safely',
         N'Error 51006; payment FAILED; no transfer',
         CONCAT(N'Unexpected success: ', @ResultCode), 'FAIL');
END TRY
BEGIN CATCH
    SELECT @FromBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @FromAccountId;
    SELECT @ToBalance = Balance FROM AFS_CoreBanking.account.Account WHERE AccountId = @ToAccountId;
    SELECT @PaymentStatus = s.StatusCode
    FROM payment.Payment AS p
    JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
    WHERE p.RequestId = @ReqFail;
    SELECT @PaymentCount = COUNT(*) FROM AFS_CoreBanking.account.Transfer WHERE RequestId = @ReqFail;

    INSERT #Results VALUES
        ('T-PAY-003', N'Insufficient funds fails payment safely',
         N'Error 51006; payment FAILED; no transfer; balances 900/600',
         CONCAT(N'Error ', ERROR_NUMBER(), N'; payment ', COALESCE(@PaymentStatus, N'missing'),
                N'; transfers ', @PaymentCount, N'; balances ', @FromBalance, N'/', @ToBalance),
         CASE WHEN ERROR_NUMBER() = 51006 AND @PaymentStatus = 'FAILED' AND @PaymentCount = 0
                   AND @FromBalance = 900 AND @ToBalance = 600
              THEN 'PASS' ELSE 'FAIL' END);
END CATCH;

SELECT TestId, TestName, Expected, Actual, Status FROM #Results ORDER BY TestId;
SELECT COUNT(*) AS TotalTests,
       SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS Passed,
       SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS Failed
FROM #Results;

IF EXISTS (SELECT 1 FROM #Results WHERE Status = 'FAIL')
    THROW 59960, N'One or more payment tests failed.', 1;

PRINT N'ALL PAYMENT TESTS PASSED.';
GO
