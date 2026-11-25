/* ============================================================================
   AFS-DBA-001
   P-01 baseline: the "as-built" processor and the controls that do not exist
   ----------------------------------------------------------------------------
   Deliberate defects, each traceable to a documented industry mechanism:
     1. no idempotency check          → duplicate submission posts twice
     2. debit and credit committed in separate autocommit statements
                                      → a failure between them leaves a credit
                                        without a debit (or a debit without credit)
     3. balance read then written as an absolute value
                                      → lost update under concurrency
     4. no reconciliation             → nobody notices until settlement review
   This file is evidence, not a template. Do not point it at real data.
   ============================================================================ */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
USE AFS_Payments;
GO

CREATE OR ALTER PROCEDURE paylab.usp_Submit_Unsafe
    @RequestId       uniqueidentifier,
    @DebitAccountId  bigint,
    @CreditAccountId bigint,
    @Amount          decimal(18,4),
    @ReadDelayMs     int           = 0,     -- application think-time between read and write
    @Fault           varchar(30)   = NULL,  -- NULL | FAIL_AFTER_DEBIT | DELAY_BEFORE_CREDIT
    @PaymentId       bigint        OUTPUT,
    @Outcome         varchar(30)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Outcome = 'UNKNOWN';

    /* 1. accept the request — with no idempotency key and no duplicate check */
    INSERT INTO paylab.PaymentIntent (RequestId, DebitAccountId, CreditAccountId, Amount, Status)
    VALUES (@RequestId, @DebitAccountId, @CreditAccountId, @Amount, 'RECEIVED');
    SET @PaymentId = SCOPE_IDENTITY();

    INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
    VALUES (@PaymentId, 'RECEIVED', CONCAT('amount=', @Amount));

    /* 2. read the balance, then write it back as an absolute value */
    DECLARE @balance decimal(18,4);
    SELECT @balance = Balance FROM paylab.Account WHERE AccountId = @DebitAccountId;

    IF @ReadDelayMs > 0
    BEGIN
        -- WAITFOR DELAY with an int is read as SECONDS; convert milliseconds explicitly
        DECLARE @readDelay varchar(12) =
            CONVERT(varchar(12), DATEADD(millisecond, @ReadDelayMs, CAST('00:00:00' AS time(3))), 114);
        WAITFOR DELAY @readDelay;   -- widened race window (injected application think-time)
    END

    IF @balance < @Amount
    BEGIN
        UPDATE paylab.PaymentIntent
           SET Status = 'FAILED', FailureCode = 'INSUFFICIENT_FUNDS', UpdatedAt = SYSUTCDATETIME()
         WHERE PaymentId = @PaymentId;
        INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
        VALUES (@PaymentId, 'FAILED', 'INSUFFICIENT_FUNDS');
        SET @Outcome = 'INSUFFICIENT_FUNDS';
        RETURN 2;
    END

    /* 3. DEBIT — committed on its own, before the credit exists */
    UPDATE paylab.Account SET Balance = @balance - @Amount WHERE AccountId = @DebitAccountId;
    INSERT INTO paylab.LedgerEntry (PaymentId, TransferRef, AccountId, Direction, Amount, BalanceAfter, Note)
    VALUES (@PaymentId, @RequestId, @DebitAccountId, 'D', @Amount, @balance - @Amount, 'debit');
    UPDATE paylab.PaymentIntent SET Status = 'DEBITED', UpdatedAt = SYSUTCDATETIME() WHERE PaymentId = @PaymentId;
    INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail) VALUES (@PaymentId, 'DEBITED', NULL);

    /* 4. injected failure: the processor dies between the two commits */
    IF @Fault = 'FAIL_AFTER_DEBIT'
    BEGIN
        INSERT INTO paylab.FaultLog (Scenario, PaymentId, FaultType, Detail)
        VALUES ('dry-posting', @PaymentId, 'PROCESSOR_CRASH',
                'process terminated after debit commit, before credit');
        INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail)
        VALUES (@PaymentId, 'ABANDONED', 'no credit posted');
        SET @Outcome = 'DRY_POSTING';
        RETURN 3;
    END

    IF @Fault = 'DELAY_BEFORE_CREDIT'
        WAITFOR DELAY '00:00:00.500';

    /* 5. CREDIT — a second independent commit */
    UPDATE paylab.Account SET Balance = Balance + @Amount WHERE AccountId = @CreditAccountId;
    DECLARE @creditBalance decimal(18,4) =
        (SELECT Balance FROM paylab.Account WHERE AccountId = @CreditAccountId);
    INSERT INTO paylab.LedgerEntry (PaymentId, TransferRef, AccountId, Direction, Amount, BalanceAfter, Note)
    VALUES (@PaymentId, @RequestId, @CreditAccountId, 'C', @Amount, @creditBalance, 'credit');

    UPDATE paylab.PaymentIntent
       SET Status = 'COMPLETED', UpdatedAt = SYSUTCDATETIME()
     WHERE PaymentId = @PaymentId;
    INSERT INTO paylab.PaymentEvent (PaymentId, EventType, Detail) VALUES (@PaymentId, 'COMPLETED', NULL);

    SET @Outcome = 'COMPLETED';
    RETURN 0;
END
GO

/* ---------------------------------------------------------------------------
   Reconciliation: compares payment intent, double-entry ledger and balances.
   Produces typed breaks, which is what the missing control should have done.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE paylab.usp_Reconcile
    @Mode  varchar(10) = 'lab',
    @RunId bigint      OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO paylab.ReconRun (Mode) VALUES (@Mode);
    SET @RunId = SCOPE_IDENTITY();

    /* debit posted, credit missing */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, PaymentId, AccountId, Detail, Amount)
    SELECT @RunId, 'ORPHAN_DEBIT', p.PaymentId, p.DebitAccountId,
           CONCAT('debit of ', d.Amount, ' has no matching credit'), d.Amount
    FROM paylab.PaymentIntent p
    JOIN paylab.LedgerEntry d ON d.PaymentId = p.PaymentId AND d.Direction = 'D'
    WHERE NOT EXISTS (SELECT 1 FROM paylab.LedgerEntry c
                      WHERE c.PaymentId = p.PaymentId AND c.Direction = 'C');

    /* credit posted, debit missing */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, PaymentId, AccountId, Detail, Amount)
    SELECT @RunId, 'ORPHAN_CREDIT', p.PaymentId, p.CreditAccountId,
           CONCAT('credit of ', c.Amount, ' has no matching debit'), c.Amount
    FROM paylab.PaymentIntent p
    JOIN paylab.LedgerEntry c ON c.PaymentId = p.PaymentId AND c.Direction = 'C'
    WHERE NOT EXISTS (SELECT 1 FROM paylab.LedgerEntry d
                      WHERE d.PaymentId = p.PaymentId AND d.Direction = 'D');

    /* more than one debit or credit for the same payment */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, PaymentId, AccountId, Detail, Amount)
    SELECT @RunId, 'DUPLICATE_POSTING', p.PaymentId, p.DebitAccountId,
           CONCAT('debits=', ISNULL(d.cnt,0), ' credits=', ISNULL(c.cnt,0)), p.Amount
    FROM paylab.PaymentIntent p
    OUTER APPLY (SELECT COUNT(*) cnt FROM paylab.LedgerEntry WHERE PaymentId = p.PaymentId AND Direction='D') d
    OUTER APPLY (SELECT COUNT(*) cnt FROM paylab.LedgerEntry WHERE PaymentId = p.PaymentId AND Direction='C') c
    WHERE ISNULL(d.cnt,0) > 1 OR ISNULL(c.cnt,0) > 1;

    /* debit and credit disagree with each other or with the intent */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, PaymentId, AccountId, Detail, Amount)
    SELECT @RunId, 'AMOUNT_MISMATCH', p.PaymentId, p.DebitAccountId,
           CONCAT('intent=', p.Amount, ' debit=', ISNULL(d.total,0), ' credit=', ISNULL(c.total,0)),
           p.Amount
    FROM paylab.PaymentIntent p
    OUTER APPLY (SELECT SUM(Amount) total FROM paylab.LedgerEntry WHERE PaymentId=p.PaymentId AND Direction='D') d
    OUTER APPLY (SELECT SUM(Amount) total FROM paylab.LedgerEntry WHERE PaymentId=p.PaymentId AND Direction='C') c
    WHERE p.Status IN ('COMPLETED','DEBITED')
      AND (ISNULL(d.total,0) <> p.Amount OR ISNULL(c.total,0) <> p.Amount);

    /* completed with no ledger entries at all */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, PaymentId, AccountId, Detail, Amount)
    SELECT @RunId, 'MISSING_POSTING', p.PaymentId, p.DebitAccountId,
           'status COMPLETED but no ledger entries', p.Amount
    FROM paylab.PaymentIntent p
    WHERE p.Status = 'COMPLETED'
      AND NOT EXISTS (SELECT 1 FROM paylab.LedgerEntry l WHERE l.PaymentId = p.PaymentId);

    /* materialised balance no longer equals opening + ledger movement */
    INSERT INTO paylab.ReconBreak (RunId, BreakType, AccountId, Detail, Amount)
    SELECT @RunId, 'BALANCE_DRIFT', a.AccountId,
           CONCAT('stored=', a.Balance, ' ledger-derived=', a.OpeningBalance + ISNULL(m.net,0)),
           a.Balance - (a.OpeningBalance + ISNULL(m.net,0))
    FROM paylab.Account a
    OUTER APPLY (
        SELECT SUM(CASE WHEN Direction = 'C' THEN Amount ELSE -Amount END) net
        FROM paylab.LedgerEntry WHERE AccountId = a.AccountId
    ) m
    WHERE a.Balance <> a.OpeningBalance + ISNULL(m.net,0);

    UPDATE paylab.ReconRun
       SET FinishedAt = SYSUTCDATETIME(),
           PaymentsChecked = (SELECT COUNT(*) FROM paylab.PaymentIntent),
           BreakCount = (SELECT COUNT(*) FROM paylab.ReconBreak WHERE RunId = @RunId)
     WHERE RunId = @RunId;
END
GO

/* ---------------------------------------------------------------------------
   Investigation queries — what an engineer would run to discover the fault.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE paylab.usp_Investigate
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 'DRY_POSTING' AS Finding, p.PaymentId, p.RequestId, p.Amount, p.Status,
           p.CreatedAt, d.BalanceAfter AS DebitBalanceAfter
    FROM paylab.PaymentIntent p
    JOIN paylab.LedgerEntry d ON d.PaymentId = p.PaymentId AND d.Direction = 'D'
    WHERE NOT EXISTS (SELECT 1 FROM paylab.LedgerEntry c
                      WHERE c.PaymentId = p.PaymentId AND c.Direction = 'C')
    ORDER BY p.PaymentId;

    SELECT 'DUPLICATE_REQUEST' AS Finding, p.RequestId, COUNT(*) AS IntentCount,
           SUM(p.Amount) AS TotalPosted
    FROM paylab.PaymentIntent p
    GROUP BY p.RequestId
    HAVING COUNT(*) > 1
    ORDER BY IntentCount DESC;

    SELECT 'BALANCE_DRIFT' AS Finding, a.AccountId, a.AccountNumber, a.OpeningBalance,
           a.Balance,
           a.OpeningBalance + ISNULL(m.net,0) AS LedgerDerived,
           a.Balance - (a.OpeningBalance + ISNULL(m.net,0)) AS Difference
    FROM paylab.Account a
    OUTER APPLY (SELECT SUM(CASE WHEN Direction='C' THEN Amount ELSE -Amount END) net
                 FROM paylab.LedgerEntry WHERE AccountId = a.AccountId) m
    WHERE a.Balance <> a.OpeningBalance + ISNULL(m.net,0)
    ORDER BY ABS(a.Balance - (a.OpeningBalance + ISNULL(m.net,0))) DESC;
END
GO

/* Trace one payment through every event and posting. */
CREATE OR ALTER PROCEDURE paylab.usp_TracePayment @PaymentId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.PaymentId, p.RequestId, p.Amount, p.Status, p.FailureCode, p.CreatedAt, p.UpdatedAt
    FROM paylab.PaymentIntent p WHERE p.PaymentId = @PaymentId;

    SELECT e.EventId, e.EventType, e.Detail, e.CreatedAt
    FROM paylab.PaymentEvent e WHERE e.PaymentId = @PaymentId ORDER BY e.EventId;

    SELECT l.EntryId, l.Direction, l.AccountId, l.Amount, l.BalanceAfter, l.OccurredAt
    FROM paylab.LedgerEntry l WHERE l.PaymentId = @PaymentId ORDER BY l.EntryId;
END
GO

PRINT 'baseline procedures created';
GO
