/* ============================================================================
   AFS-DBA-001
   P-01 fix: atomic, idempotent, auditable payment posting
   ----------------------------------------------------------------------------
   Changes, each mapped to a validation test:
     1. unique idempotency key      → replay cannot post twice
     2. single transaction          → debit and credit commit or neither does
     3. guarded UPDATE              → concurrency cannot spend the same balance
     4. ledger invariant checked
        inside the transaction      → imbalance rolls back
     5. explicit terminal states    → ambiguous outcomes are visible
     6. transactional outbox        → no event is lost between commit and publish
     7. exception queue             → failures are queued, not swallowed
   ============================================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
USE AFS_Payments;
GO

/* Idempotency is enforced by the database, not by application hope.
   Filtered indexes require QUOTED_IDENTIFIER ON, set above. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_paylab_Intent_Idempotency')
    CREATE UNIQUE INDEX UX_paylab_Intent_Idempotency
        ON paylab.PaymentIntent(IdempotencyKey)
        WHERE IdempotencyKey IS NOT NULL;
GO

CREATE OR ALTER PROCEDURE paylab.usp_Submit_Safe
    @IdempotencyKey  varchar(64),
    @RequestId       uniqueidentifier,
    @DebitAccountId  bigint,
    @CreditAccountId bigint,
    @Amount          decimal(18,4),
    @Fault           varchar(20) = NULL,  -- NULL | FAIL_AFTER_DEBIT (fault injection for the atomicity test)
    @PaymentId       bigint      OUTPUT,
    @Result          int         OUTPUT   -- 0 posted, 1 idempotent replay, 2 declined, 3 failed
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @Result = 3;
    SET @PaymentId = NULL;

    IF @IdempotencyKey IS NULL OR LEN(@IdempotencyKey) = 0
    BEGIN
        THROW 50010, 'idempotency key is required', 1;
    END

    /* fast replay path */
    SELECT @PaymentId = PaymentId FROM paylab.PaymentIntent WHERE IdempotencyKey = @IdempotencyKey;
    IF @PaymentId IS NOT NULL
    BEGIN
        SET @Result = 1;
        RETURN 1;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO paylab.PaymentIntent
            (RequestId, IdempotencyKey, DebitAccountId, CreditAccountId, Amount, Status)
        VALUES
            (@RequestId, @IdempotencyKey, @DebitAccountId, @CreditAccountId, @Amount, 'PENDING');

        SET @PaymentId = SCOPE_IDENTITY();

        INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
        VALUES (@PaymentId, 'RECEIVED', CONCAT('amount=', @Amount, ' key=', @IdempotencyKey));

        /* guarded debit: the predicate is evaluated inside the update, under lock */
        UPDATE paylab.Account
           SET Balance = Balance - @Amount
         WHERE AccountId = @DebitAccountId
           AND Balance >= @Amount;

        IF @@ROWCOUNT = 0
        BEGIN
            ROLLBACK TRANSACTION;

            /* record the decline as a terminal outcome, then exit */
            INSERT INTO paylab.PaymentIntent
                (RequestId, IdempotencyKey, DebitAccountId, CreditAccountId, Amount, Status, FailureCode)
            VALUES
                (@RequestId, @IdempotencyKey, @DebitAccountId, @CreditAccountId, @Amount, 'FAILED', 'INSUFFICIENT_FUNDS');

            SET @PaymentId = SCOPE_IDENTITY();
            INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
            VALUES (@PaymentId, 'FAILED', 'INSUFFICIENT_FUNDS');

            SET @Result = 2;
            RETURN 2;
        END

        DECLARE @debitBalance decimal(18,4) =
            (SELECT Balance FROM paylab.Account WHERE AccountId = @DebitAccountId);

        INSERT INTO paylab.LedgerEntry
            (PaymentId, TransferRef, AccountId, Direction, Amount, BalanceAfter, Note)
        VALUES
            (@PaymentId, @RequestId, @DebitAccountId, 'D', @Amount, @debitBalance, 'debit');

        /* injected downstream failure: proves the debit is rolled back, not orphaned */
        IF @Fault = 'FAIL_AFTER_DEBIT'
            THROW 50002, 'injected failure after debit', 1;

        UPDATE paylab.Account
           SET Balance = Balance + @Amount
         WHERE AccountId = @CreditAccountId;

        DECLARE @creditBalance decimal(18,4) =
            (SELECT Balance FROM paylab.Account WHERE AccountId = @CreditAccountId);

        INSERT INTO paylab.LedgerEntry
            (PaymentId, TransferRef, AccountId, Direction, Amount, BalanceAfter, Note)
        VALUES
            (@PaymentId, @RequestId, @CreditAccountId, 'C', @Amount, @creditBalance, 'credit');

        /* double-entry invariant, enforced before commit */
        IF EXISTS (
            SELECT 1
            FROM paylab.LedgerEntry
            WHERE PaymentId = @PaymentId
            GROUP BY PaymentId
            HAVING SUM(CASE WHEN Direction = 'D' THEN Amount ELSE -Amount END) <> 0
                OR COUNT(*) <> 2
        )
            THROW 50001, 'ledger invariant violated for payment', 1;

        UPDATE paylab.PaymentIntent
           SET Status = 'COMPLETED', UpdatedAt = SYSUTCDATETIME()
         WHERE PaymentId = @PaymentId;

        INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
        VALUES (@PaymentId, 'COMPLETED', 'debit and credit committed atomically');

        /* outbox row is in the same transaction: no lost event */
        INSERT INTO paylab.Outbox (PaymentId, EventType, Payload)
        VALUES (@PaymentId, 'PAYMENT_COMPLETED',
                CONCAT('{"paymentId":', @PaymentId, ',"amount":', @Amount, '}'));

        COMMIT TRANSACTION;
        SET @Result = 0;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        /* concurrent duplicate: the unique index won the race */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT @PaymentId = PaymentId FROM paylab.PaymentIntent WHERE IdempotencyKey = @IdempotencyKey;
            SET @Result = 1;
            RETURN 1;
        END

        BEGIN TRY
            INSERT INTO paylab.PaymentIntent
                (RequestId, IdempotencyKey, DebitAccountId, CreditAccountId, Amount, Status, FailureCode)
            VALUES
                (@RequestId, @IdempotencyKey, @DebitAccountId, @CreditAccountId, @Amount, 'FAILED', 'POSTING_ERROR');

            SET @PaymentId = SCOPE_IDENTITY();

            INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
            VALUES (@PaymentId, 'FAILED', LEFT(ERROR_MESSAGE(), 250));

            INSERT INTO paylab.ExceptionQueue (PaymentId, Reason, Detail)
            VALUES (@PaymentId, 'POSTING_ERROR', LEFT(ERROR_MESSAGE(), 350));
        END TRY
        BEGIN CATCH
            /* if even the failure record cannot be written, the caller still gets 3 */
        END CATCH

        SET @Result = 3;
        RETURN 3;
    END CATCH
END
GO

/* Outbox publisher: marks rows dispatched. Failure between commit and publish
   is recoverable because the row is already durable. */
CREATE OR ALTER PROCEDURE paylab.usp_PublishOutbox @BatchSize int = 100
AS
BEGIN
    SET NOCOUNT ON;
    WITH next AS (
        SELECT TOP (@BatchSize) OutboxId
        FROM paylab.Outbox
        WHERE PublishedAt IS NULL
        ORDER BY OutboxId
    )
    UPDATE o SET PublishedAt = SYSUTCDATETIME()
    FROM paylab.Outbox o JOIN next n ON n.OutboxId = o.OutboxId;
    SELECT @@ROWCOUNT AS published;
END
GO

/* Inbox dedupe: a redelivered message is recorded once. */
CREATE OR ALTER PROCEDURE paylab.usp_ProcessInbox
    @MessageId uniqueidentifier,
    @PaymentId bigint = NULL,
    @Result    int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Result = 0;
    BEGIN TRY
        INSERT INTO paylab.Inbox (MessageId, PaymentId) VALUES (@MessageId, @PaymentId);
        SET @Result = 1;   -- processed
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627) SET @Result = 0;  -- duplicate, ignored
        ELSE THROW;
    END CATCH
END
GO

PRINT 'fixed procedures created';
GO
