/*
  AFS-DBA-001
  Purpose: Payment orchestration around the authoritative Core transfer engine.
  Safety: Payment creation is idempotent by RequestId. A payment is committed
          PENDING before money moves; the financial posting itself is atomic in
          Core. A crash between the two steps leaves a PENDING payment for the
          reconciliation procedure, never a partial ledger posting.
  Prerequisites: Core transfer procedure, payment tables, reference data.
*/

USE [AFS_Payments];
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE payment.usp_ExecutePendingPayment
    @PaymentId     BIGINT,
    @TransferId    UNIQUEIDENTIFIER = NULL OUTPUT,
    @ResultCode    VARCHAR(20) = NULL OUTPUT,
    @ResultMessage NVARCHAR(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @RequestId UNIQUEIDENTIFIER;
    DECLARE @DebitAccountId BIGINT;
    DECLARE @BeneficiaryAccountId BIGINT;
    DECLARE @Amount DECIMAL(19,4);
    DECLARE @CurrencyCode CHAR(3);
    DECLARE @Description NVARCHAR(200);
    DECLARE @StatusCode VARCHAR(20);
    DECLARE @StatusId INT;
    DECLARE @PendingStatusId INT;
    DECLARE @CompletedStatusId INT;
    DECLARE @FailedStatusId INT;
    DECLARE @ErrorNumber INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;
    DECLARE @EventData NVARCHAR(MAX);

    SELECT @PendingStatusId = PaymentStatusId FROM payment.PaymentStatus WHERE StatusCode = 'PENDING';
    SELECT @CompletedStatusId = PaymentStatusId FROM payment.PaymentStatus WHERE StatusCode = 'COMPLETED';
    SELECT @FailedStatusId = PaymentStatusId FROM payment.PaymentStatus WHERE StatusCode = 'FAILED';

    IF @PendingStatusId IS NULL OR @CompletedStatusId IS NULL OR @FailedStatusId IS NULL
        THROW 52000, N'Payment status reference data is incomplete.', 1;

    SELECT
        @RequestId = p.RequestId,
        @DebitAccountId = p.DebitAccountId,
        @BeneficiaryAccountId = p.BeneficiaryAccountId,
        @Amount = p.Amount,
        @CurrencyCode = p.CurrencyCode,
        @Description = N'Payment ' + p.PaymentReference,
        @StatusId = p.PaymentStatusId,
        @StatusCode = s.StatusCode,
        @TransferId = p.TransferId
    FROM payment.Payment AS p
    JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
    WHERE p.PaymentId = @PaymentId;

    IF @RequestId IS NULL
        THROW 52001, N'Payment not found.', 1;

    IF @StatusCode <> 'PENDING'
    BEGIN
        SET @ResultCode = @StatusCode;
        SET @ResultMessage = N'Payment is not pending; no new transfer was attempted.';
        RETURN 0;
    END

    BEGIN TRY
        EXEC AFS_CoreBanking.account.usp_ExecuteTransfer
            @RequestId = @RequestId,
            @FromAccountId = @DebitAccountId,
            @ToAccountId = @BeneficiaryAccountId,
            @Amount = @Amount,
            @CurrencyCode = @CurrencyCode,
            @Description = @Description,
            @TransferId = @TransferId OUTPUT,
            @ResultCode = @ResultCode OUTPUT,
            @ResultMessage = @ResultMessage OUTPUT;

        UPDATE payment.Payment
        SET PaymentStatusId = @CompletedStatusId,
            TransferId = @TransferId,
            ProcessedAt = @Now,
            FailureCode = NULL,
            FailureMessage = NULL
        WHERE PaymentId = @PaymentId
          AND PaymentStatusId = @PendingStatusId;

        IF @@ROWCOUNT <> 1
            THROW 52002, N'Payment status changed before completion; investigate concurrency.', 1;

        SET @EventData =
        (
            SELECT @PaymentId AS paymentId, @TransferId AS transferId,
                   @ResultCode AS transferResult, @Now AS completedAt
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        INSERT payment.PaymentEvent (PaymentId, EventType, EventData, Actor)
        VALUES (@PaymentId, 'COMPLETED', @EventData, SUSER_SNAME());

        INSERT audit.AuditEvent (EventType, EntityType, EntityId, Actor, CorrelationId, EventData)
        VALUES ('PAYMENT_COMPLETED', 'Payment', CONVERT(NVARCHAR(30), @PaymentId),
                SUSER_SNAME(), @RequestId, @EventData);

        SET @ResultCode = 'COMPLETED';
        SET @ResultMessage = N'Payment completed.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @ErrorSeverity = ERROR_SEVERITY();
        SET @ErrorState = ERROR_STATE();

        -- Best effort: mark the payment failed so it is visible to operations.
        BEGIN TRY
            UPDATE payment.Payment
            SET PaymentStatusId = @FailedStatusId,
                ProcessedAt = @Now,
                FailureCode = LEFT(CONVERT(VARCHAR(50), @ErrorNumber), 50),
                FailureMessage = LEFT(@ErrorMessage, 400)
            WHERE PaymentId = @PaymentId
              AND PaymentStatusId = @PendingStatusId;

            SET @EventData =
            (
                SELECT @PaymentId AS paymentId, @ErrorNumber AS errorNumber,
                       @ErrorMessage AS errorMessage, @Now AS failedAt
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            INSERT payment.PaymentEvent (PaymentId, EventType, EventData, Actor)
            VALUES (@PaymentId, 'FAILED', @EventData, SUSER_SNAME());

            INSERT audit.AuditEvent (EventType, EntityType, EntityId, Actor, CorrelationId, EventData)
            VALUES ('PAYMENT_FAILED', 'Payment', CONVERT(NVARCHAR(30), @PaymentId),
                    SUSER_SNAME(), @RequestId, @EventData);
        END TRY
        BEGIN CATCH
            -- Preserve the original transfer error.
        END CATCH;

        THROW @ErrorNumber, @ErrorMessage, @ErrorState;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE payment.usp_CreatePayment
    @RequestId                UNIQUEIDENTIFIER,
    @DebitAccountId           BIGINT,
    @BeneficiaryAccountId     BIGINT,
    @BeneficiaryName          NVARCHAR(200),
    @BeneficiaryAccountNumber NVARCHAR(34),
    @Amount                   DECIMAL(19,4),
    @CurrencyCode             CHAR(3),
    @PaymentMethodCode        VARCHAR(20),
    @PaymentId                BIGINT = NULL OUTPUT,
    @PaymentReference         VARCHAR(24) = NULL OUTPUT,
    @TransferId               UNIQUEIDENTIFIER = NULL OUTPUT,
    @ResultCode               VARCHAR(20) = NULL OUTPUT,
    @ResultMessage            NVARCHAR(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @PaymentMethodId INT;
    DECLARE @PendingStatusId INT;
    DECLARE @ExistingStatus VARCHAR(20);
    DECLARE @PaymentReferenceSeq BIGINT;

    SET @CurrencyCode = UPPER(LTRIM(RTRIM(@CurrencyCode)));

    IF @RequestId IS NULL
        THROW 52010, N'RequestId is required.', 1;
    IF @DebitAccountId IS NULL OR @BeneficiaryAccountId IS NULL
        THROW 52010, N'Debit and beneficiary account IDs are required.', 1;
    IF @DebitAccountId = @BeneficiaryAccountId
        THROW 52010, N'Debit and beneficiary accounts must be different.', 1;
    IF @Amount IS NULL OR @Amount <= 0
        THROW 52010, N'Payment amount must be greater than zero.', 1;
    IF @CurrencyCode IS NULL OR LEN(@CurrencyCode) <> 3
        THROW 52010, N'A three-character currency code is required.', 1;
    IF LEN(LTRIM(RTRIM(@BeneficiaryName))) = 0
        THROW 52010, N'Beneficiary name is required.', 1;
    IF LEN(LTRIM(RTRIM(@BeneficiaryAccountNumber))) NOT BETWEEN 6 AND 34
        THROW 52010, N'Beneficiary account number must be 6-34 characters.', 1;

    SELECT @PaymentMethodId = PaymentMethodId
    FROM payment.PaymentMethod
    WHERE MethodCode = @PaymentMethodCode AND IsActive = 1;

    IF @PaymentMethodId IS NULL
        THROW 52011, N'Unknown or inactive payment method.', 1;

    SELECT @PendingStatusId = PaymentStatusId
    FROM payment.PaymentStatus
    WHERE StatusCode = 'PENDING';

    IF @PendingStatusId IS NULL
        THROW 52012, N'PENDING payment status is missing.', 1;

    -- Idempotent lookup. A completed/failed/cancelled payment is returned
    -- without creating a second financial transaction. A pending payment is
    -- re-driven through the Core engine, which itself is idempotent. Clear the
    -- OUTPUT parameters first: callers often reuse variables across calls, and
    -- a stale PaymentId would make a new request look like an existing one.
    SET @PaymentId = NULL;
    SET @PaymentReference = NULL;
    SET @TransferId = NULL;
    SET @ExistingStatus = NULL;

    SELECT
        @PaymentId = p.PaymentId,
        @PaymentReference = p.PaymentReference,
        @TransferId = p.TransferId,
        @ExistingStatus = s.StatusCode
    FROM payment.Payment AS p
    JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
    WHERE p.RequestId = @RequestId;

    IF @PaymentId IS NOT NULL
    BEGIN
        IF @ExistingStatus = 'PENDING'
        BEGIN
            EXEC payment.usp_ExecutePendingPayment
                @PaymentId = @PaymentId,
                @TransferId = @TransferId OUTPUT,
                @ResultCode = @ResultCode OUTPUT,
                @ResultMessage = @ResultMessage OUTPUT;
            RETURN 0;
        END

        SET @ResultCode = @ExistingStatus;
        SET @ResultMessage = N'Existing payment returned; no new transfer was created.';
        RETURN 0;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        SET @PaymentReferenceSeq = NEXT VALUE FOR payment.PaymentReferenceSequence;

        SET @PaymentReference =
            'PAY' + CONVERT(CHAR(8), @Now, 112)
            + RIGHT('00000000' + CONVERT(VARCHAR(8), @PaymentReferenceSeq), 8);

        INSERT payment.Payment
        (
            PaymentReference, RequestId, DebitAccountId, BeneficiaryAccountId,
            BeneficiaryName, BeneficiaryAccountNumber, Amount, CurrencyCode,
            PaymentMethodId, PaymentStatusId, CreatedAt
        )
        VALUES
        (
            @PaymentReference, @RequestId, @DebitAccountId, @BeneficiaryAccountId,
            @BeneficiaryName, @BeneficiaryAccountNumber, @Amount, @CurrencyCode,
            @PaymentMethodId, @PendingStatusId, @Now
        );

        SET @PaymentId = SCOPE_IDENTITY();

        INSERT payment.PaymentEvent (PaymentId, EventType, EventData, Actor)
        VALUES
        (
            @PaymentId, 'CREATED',
            (SELECT @PaymentId AS paymentId, @RequestId AS requestId, @Amount AS amount,
                    @CurrencyCode AS currencyCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            SUSER_SNAME()
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        -- Two concurrent requests can both pass the pre-check. The unique
        -- Payment.RequestId index chooses a winner; return the winner's
        -- payment instead of exposing a duplicate-key error to the caller.
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT
                @PaymentId = p.PaymentId,
                @PaymentReference = p.PaymentReference,
                @TransferId = p.TransferId,
                @ExistingStatus = s.StatusCode
            FROM payment.Payment AS p
            JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
            WHERE p.RequestId = @RequestId;

            IF @PaymentId IS NOT NULL
            BEGIN
                IF @ExistingStatus = 'PENDING'
                BEGIN
                    EXEC payment.usp_ExecutePendingPayment
                        @PaymentId = @PaymentId,
                        @TransferId = @TransferId OUTPUT,
                        @ResultCode = @ResultCode OUTPUT,
                        @ResultMessage = @ResultMessage OUTPUT;
                    RETURN 0;
                END

                SET @ResultCode = @ExistingStatus;
                SET @ResultMessage = N'Concurrent duplicate returned; no new transfer was created.';
                RETURN 0;
            END
        END;

        THROW;
    END CATCH;

    EXEC payment.usp_ExecutePendingPayment
        @PaymentId = @PaymentId,
        @TransferId = @TransferId OUTPUT,
        @ResultCode = @ResultCode OUTPUT,
        @ResultMessage = @ResultMessage OUTPUT;

    RETURN 0;
END
GO

CREATE OR ALTER PROCEDURE payment.usp_GetPayment
    @PaymentId BIGINT = NULL,
    @PaymentReference VARCHAR(24) = NULL,
    @RequestId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PaymentId,
        p.PaymentReference,
        p.RequestId,
        p.DebitAccountId,
        p.BeneficiaryAccountId,
        p.BeneficiaryName,
        p.BeneficiaryAccountNumber,
        p.Amount,
        p.CurrencyCode,
        m.MethodCode AS PaymentMethod,
        s.StatusCode AS PaymentStatus,
        p.TransferId,
        p.FailureCode,
        p.FailureMessage,
        p.CreatedAt,
        p.ProcessedAt
    FROM payment.Payment AS p
    JOIN payment.PaymentMethod AS m ON m.PaymentMethodId = p.PaymentMethodId
    JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
    WHERE (@PaymentId IS NOT NULL AND p.PaymentId = @PaymentId)
       OR (@PaymentReference IS NOT NULL AND p.PaymentReference = @PaymentReference)
       OR (@RequestId IS NOT NULL AND p.RequestId = @RequestId);
END
GO

CREATE OR ALTER PROCEDURE payment.usp_ReconcilePayments
AS
BEGIN
    SET NOCOUNT ON;

    -- Payments that claim completion without an authoritative transfer, or
    -- whose transfer details disagree, are reconciliation exceptions.
    SELECT
        p.PaymentId,
        p.PaymentReference,
        p.RequestId,
        p.Amount AS PaymentAmount,
        p.CurrencyCode AS PaymentCurrency,
        p.TransferId,
        s.StatusCode AS PaymentStatus,
        t.Amount AS TransferAmount,
        t.CurrencyCode AS TransferCurrency,
        p.CreatedAt,
        CASE
            WHEN p.TransferId IS NOT NULL AND t.TransferId IS NULL THEN 'MISSING_TRANSFER'
            WHEN s.StatusCode = 'COMPLETED' AND p.TransferId IS NULL THEN 'COMPLETED_WITHOUT_TRANSFER'
            WHEN t.TransferId IS NOT NULL AND (t.Amount <> p.Amount OR t.CurrencyCode <> p.CurrencyCode)
                THEN 'TRANSFER_MISMATCH'
            WHEN s.StatusCode = 'PENDING' AND p.CreatedAt < DATEADD(MINUTE, -15, SYSUTCDATETIME())
                THEN 'STALE_PENDING'
            ELSE 'OK'
        END AS ExceptionType
    FROM payment.Payment AS p
    JOIN payment.PaymentStatus AS s ON s.PaymentStatusId = p.PaymentStatusId
    LEFT JOIN AFS_CoreBanking.account.Transfer AS t ON t.TransferId = p.TransferId
    WHERE (p.TransferId IS NOT NULL AND t.TransferId IS NULL)
       OR (s.StatusCode = 'COMPLETED' AND p.TransferId IS NULL)
       OR (t.TransferId IS NOT NULL AND (t.Amount <> p.Amount OR t.CurrencyCode <> p.CurrencyCode))
       OR (s.StatusCode = 'PENDING' AND p.CreatedAt < DATEADD(MINUTE, -15, SYSUTCDATETIME()));
END
GO

PRINT N'Payment procedures created.';
GO
