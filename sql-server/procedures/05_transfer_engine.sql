/*
  AFS-DBA-001
  Purpose: Atomic transfer engine and reconciliation procedures.
  Safety: Procedure is safe to call repeatedly with the same RequestId; it returns
          the original transfer instead of posting again.
  Prerequisites: Core tables, reference data, indexes.
  Run as: AFS_DBA to create; AFS_App to execute the transfer procedure.
  Invariants:
    - one debit and one credit ledger entry per completed transfer;
    - maintained balance equals OpeningBalance + ledger sum (checked by reconciliation);
    - failed posting leaves no balance or ledger change;
    - duplicate RequestId does not duplicate money movement.
*/

USE [AFS_CoreBanking];
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE account.usp_ExecuteTransfer
    @RequestId       UNIQUEIDENTIFIER,
    @FromAccountId   BIGINT,
    @ToAccountId     BIGINT,
    @Amount          DECIMAL(19,4),
    @CurrencyCode    CHAR(3),
    @Description     NVARCHAR(200) = NULL,
    @CorrelationId   UNIQUEIDENTIFIER = NULL,
    @TransferId      UNIQUEIDENTIFIER = NULL OUTPUT,
    @ResultCode      VARCHAR(20) = NULL OUTPUT,
    @ResultMessage   NVARCHAR(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @ExistingTransferId UNIQUEIDENTIFIER;
    DECLARE @ErrorNumber INT;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @ErrorSeverity INT;
    DECLARE @ErrorState INT;

    DECLARE @FromFound BIT = 0;
    DECLARE @ToFound BIT = 0;
    DECLARE @FromAllowsTransfers BIT;
    DECLARE @ToAllowsTransfers BIT;
    DECLARE @FromCurrency CHAR(3);
    DECLARE @ToCurrency CHAR(3);
    DECLARE @FromBalance DECIMAL(19,4);
    DECLARE @ToBalance DECIMAL(19,4);
    DECLARE @FromOverdraft DECIMAL(19,4);
    DECLARE @FromPerTransferLimit DECIMAL(19,4);
    DECLARE @FromDailyLimit DECIMAL(19,4);
    DECLARE @DailyDebits DECIMAL(19,4) = 0;
    DECLARE @DayStart DATETIME2(3);
    DECLARE @DayEnd DATETIME2(3);
    DECLARE @TransferData NVARCHAR(MAX);
    DECLARE @FailureData NVARCHAR(MAX);
    DECLARE @FromBalanceAfter DECIMAL(19,4);
    DECLARE @ToBalanceAfter DECIMAL(19,4);

    SET @ResultCode = 'FAILED';
    SET @ResultMessage = NULL;
    SET @CurrencyCode = UPPER(LTRIM(RTRIM(@CurrencyCode)));

    IF @RequestId IS NULL
        THROW 51000, N'RequestId is required for idempotency.', 1;
    IF @FromAccountId IS NULL OR @ToAccountId IS NULL
        THROW 51000, N'FromAccountId and ToAccountId are required.', 1;
    IF @FromAccountId = @ToAccountId
        THROW 51000, N'Sender and recipient accounts must be different.', 1;
    IF @Amount IS NULL OR @Amount <= 0
        THROW 51000, N'Transfer amount must be greater than zero.', 1;
    IF @CurrencyCode IS NULL OR LEN(@CurrencyCode) <> 3
        THROW 51000, N'A three-character currency code is required.', 1;

    IF @CorrelationId IS NULL
        SET @CorrelationId = NEWID();
    IF @TransferId IS NULL
        SET @TransferId = NEWID();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Idempotency check. UPDLOCK/HOLDLOCK plus the unique index closes the
        -- race between two concurrent retries with the same RequestId.
        SELECT @ExistingTransferId = t.TransferId
        FROM account.Transfer AS t WITH (UPDLOCK, HOLDLOCK)
        WHERE t.RequestId = @RequestId;

        IF @ExistingTransferId IS NOT NULL
        BEGIN
            SET @TransferId = @ExistingTransferId;
            SET @ResultCode = 'DUPLICATE';
            SET @ResultMessage = N'Request already completed; existing transfer returned.';
            COMMIT TRANSACTION;
            RETURN 0;
        END

        -- Lock both accounts in ascending AccountId order to make opposite
        -- direction transfers acquire locks in the same order.
        IF @FromAccountId < @ToAccountId
        BEGIN
            SELECT @FromFound = 1,
                   @FromAllowsTransfers = s.AllowsTransfers,
                   @FromCurrency = a.CurrencyCode,
                   @FromBalance = a.Balance,
                   @FromOverdraft = a.OverdraftLimit,
                   @FromPerTransferLimit = a.PerTransferLimit,
                   @FromDailyLimit = a.DailyTransferLimit
            FROM account.Account AS a WITH (UPDLOCK, HOLDLOCK)
            JOIN reference.AccountStatus AS s
              ON s.AccountStatusId = a.AccountStatusId
            WHERE a.AccountId = @FromAccountId;

            IF @@ROWCOUNT = 0 SET @FromFound = 0;

            SELECT @ToFound = 1,
                   @ToAllowsTransfers = s.AllowsTransfers,
                   @ToCurrency = a.CurrencyCode,
                   @ToBalance = a.Balance
            FROM account.Account AS a WITH (UPDLOCK, HOLDLOCK)
            JOIN reference.AccountStatus AS s
              ON s.AccountStatusId = a.AccountStatusId
            WHERE a.AccountId = @ToAccountId;

            IF @@ROWCOUNT = 0 SET @ToFound = 0;
        END
        ELSE
        BEGIN
            SELECT @ToFound = 1,
                   @ToAllowsTransfers = s.AllowsTransfers,
                   @ToCurrency = a.CurrencyCode,
                   @ToBalance = a.Balance
            FROM account.Account AS a WITH (UPDLOCK, HOLDLOCK)
            JOIN reference.AccountStatus AS s
              ON s.AccountStatusId = a.AccountStatusId
            WHERE a.AccountId = @ToAccountId;

            IF @@ROWCOUNT = 0 SET @ToFound = 0;

            SELECT @FromFound = 1,
                   @FromAllowsTransfers = s.AllowsTransfers,
                   @FromCurrency = a.CurrencyCode,
                   @FromBalance = a.Balance,
                   @FromOverdraft = a.OverdraftLimit,
                   @FromPerTransferLimit = a.PerTransferLimit,
                   @FromDailyLimit = a.DailyTransferLimit
            FROM account.Account AS a WITH (UPDLOCK, HOLDLOCK)
            JOIN reference.AccountStatus AS s
              ON s.AccountStatusId = a.AccountStatusId
            WHERE a.AccountId = @FromAccountId;

            IF @@ROWCOUNT = 0 SET @FromFound = 0;
        END

        IF @FromFound = 0 OR @ToFound = 0
            THROW 51001, N'One or both accounts do not exist.', 1;

        IF @FromAllowsTransfers = 0 OR @ToAllowsTransfers = 0
            THROW 51002, N'One or both accounts are not permitted to transfer.', 1;

        IF @FromCurrency <> @CurrencyCode OR @ToCurrency <> @CurrencyCode
            THROW 51003, N'Account currency does not match the transfer currency.', 1;

        IF @Amount > @FromPerTransferLimit
            THROW 51004, N'Amount exceeds the sender per-transfer limit.', 1;

        SET @DayStart = CONVERT(DATETIME2(3), CONVERT(DATE, @Now));
        SET @DayEnd = DATEADD(DAY, 1, @DayStart);

        SELECT @DailyDebits = ISNULL(SUM(-l.Amount), 0)
        FROM account.AccountLedgerEntry AS l
        WHERE l.AccountId = @FromAccountId
          AND l.EntryType = 'DEBIT'
          AND l.OccurredAt >= @DayStart
          AND l.OccurredAt < @DayEnd;

        IF @DailyDebits + @Amount > @FromDailyLimit
            THROW 51005, N'Amount exceeds the sender daily transfer limit.', 1;

        IF @FromBalance - @Amount < -@FromOverdraft
            THROW 51006, N'Insufficient available balance.', 1;

        -- Insert the authoritative transfer before posting the ledger entries.
        INSERT account.Transfer
        (
            TransferId, RequestId, FromAccountId, ToAccountId, Amount,
            CurrencyCode, Status, Description, CorrelationId, CreatedAt, CompletedAt
        )
        VALUES
        (
            @TransferId, @RequestId, @FromAccountId, @ToAccountId, @Amount,
            @CurrencyCode, 'COMPLETED', @Description, @CorrelationId, @Now, @Now
        );

        UPDATE account.Account
        SET Balance = Balance - @Amount,
            UpdatedAt = @Now
        WHERE AccountId = @FromAccountId
          AND Balance - @Amount >= -OverdraftLimit;

        IF @@ROWCOUNT <> 1
            THROW 51007, N'Sender balance update failed; the transfer was rolled back.', 1;

        UPDATE account.Account
        SET Balance = Balance + @Amount,
            UpdatedAt = @Now
        WHERE AccountId = @ToAccountId;

        IF @@ROWCOUNT <> 1
            THROW 51008, N'Recipient balance update failed; the transfer was rolled back.', 1;

        SET @FromBalanceAfter = @FromBalance - @Amount;
        SET @ToBalanceAfter = @ToBalance + @Amount;

        INSERT account.AccountLedgerEntry
        (
            TransferId, AccountId, EntryType, Amount, BalanceAfter,
            CurrencyCode, OccurredAt, Description
        )
        VALUES
            (@TransferId, @FromAccountId, 'DEBIT', -@Amount, @FromBalanceAfter,
             @CurrencyCode, @Now, @Description),
            (@TransferId, @ToAccountId, 'CREDIT', @Amount, @ToBalanceAfter,
             @CurrencyCode, @Now, @Description);

        SET @TransferData =
        (
            SELECT
                @TransferId AS transferId,
                @RequestId AS requestId,
                @FromAccountId AS fromAccountId,
                @ToAccountId AS toAccountId,
                @Amount AS amount,
                @CurrencyCode AS currencyCode,
                @FromBalanceAfter AS fromBalanceAfter,
                @ToBalanceAfter AS toBalanceAfter,
                @CorrelationId AS correlationId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        INSERT account.TransferEvent (TransferId, EventType, EventData, Actor)
        VALUES (@TransferId, 'COMPLETED', @TransferData, SUSER_SNAME());

        INSERT audit.AuditEvent
        (
            EventType, EntityType, EntityId, Actor, CorrelationId, EventData
        )
        VALUES
        (
            'TRANSFER_COMPLETED', 'Transfer', CONVERT(NVARCHAR(36), @TransferId),
            SUSER_SNAME(), @CorrelationId, @TransferData
        );

        COMMIT TRANSACTION;

        SET @ResultCode = 'COMPLETED';
        SET @ResultMessage = N'Transfer completed.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        SET @ErrorNumber = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();
        SET @ErrorSeverity = ERROR_SEVERITY();
        SET @ErrorState = ERROR_STATE();

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        -- A concurrent retry can lose the unique-key race. If the winning
        -- request completed, return its transfer rather than reporting a
        -- duplicate-key failure to the caller.
        IF @ErrorNumber IN (2601, 2627)
        BEGIN
            SELECT @ExistingTransferId = t.TransferId
            FROM account.Transfer AS t
            WHERE t.RequestId = @RequestId;

            IF @ExistingTransferId IS NOT NULL
            BEGIN
                SET @TransferId = @ExistingTransferId;
                SET @ResultCode = 'DUPLICATE';
                SET @ResultMessage = N'Request already completed; existing transfer returned.';
                RETURN 0;
            END
        END

        -- Best-effort failure audit. If this insert fails, the original error
        -- below is still raised; the procedure never reports success.
        BEGIN TRY
            SET @FailureData =
            (
                SELECT
                    @RequestId AS requestId,
                    @FromAccountId AS fromAccountId,
                    @ToAccountId AS toAccountId,
                    @Amount AS amount,
                    @CurrencyCode AS currencyCode,
                    @ErrorNumber AS errorNumber,
                    @ErrorMessage AS errorMessage,
                    @Now AS attemptedAt
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
            );

            INSERT audit.AuditEvent
            (
                EventType, EntityType, EntityId, Actor, CorrelationId, EventData
            )
            VALUES
            (
                'TRANSFER_FAILED', 'Transfer',
                COALESCE(CONVERT(NVARCHAR(36), @RequestId), N'unknown'),
                SUSER_SNAME(), @CorrelationId, @FailureData
            );
        END TRY
        BEGIN CATCH
            -- Intentionally empty: preserve the original error.
        END CATCH;

        THROW @ErrorNumber, @ErrorMessage, @ErrorState;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE account.usp_GetAccountSummary
    @AccountId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.AccountId,
        a.AccountNumber,
        a.CustomerId,
        at.TypeCode AS AccountType,
        st.StatusCode AS AccountStatus,
        a.CurrencyCode,
        a.Balance,
        a.OpeningBalance,
        a.OverdraftLimit,
        a.Balance + a.OverdraftLimit AS AvailableBalance,
        a.PerTransferLimit,
        a.DailyTransferLimit,
        a.OpenedAt,
        a.ClosedAt,
        a.UpdatedAt
    FROM account.Account AS a
    JOIN reference.AccountType AS at ON at.AccountTypeId = a.AccountTypeId
    JOIN reference.AccountStatus AS st ON st.AccountStatusId = a.AccountStatusId
    WHERE a.AccountId = @AccountId;
END
GO

CREATE OR ALTER PROCEDURE account.usp_GetTransfer
    @TransferId UNIQUEIDENTIFIER = NULL,
    @RequestId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.TransferId,
        t.RequestId,
        t.FromAccountId,
        t.ToAccountId,
        t.Amount,
        t.CurrencyCode,
        t.Status,
        t.Description,
        t.CorrelationId,
        t.CreatedAt,
        t.CompletedAt
    FROM account.Transfer AS t
    WHERE (@TransferId IS NOT NULL AND t.TransferId = @TransferId)
       OR (@RequestId IS NOT NULL AND t.RequestId = @RequestId);
END
GO

CREATE OR ALTER PROCEDURE account.usp_ReconcileBalances
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH LedgerTotals AS
    (
        SELECT l.AccountId, SUM(l.Amount) AS LedgerBalance
        FROM account.AccountLedgerEntry AS l
        GROUP BY l.AccountId
    )
    SELECT
        a.AccountId,
        a.AccountNumber,
        a.OpeningBalance,
        a.Balance AS MaintainedBalance,
        ISNULL(lt.LedgerBalance, 0) AS LedgerBalance,
        a.OpeningBalance + ISNULL(lt.LedgerBalance, 0) AS ExpectedBalance,
        a.Balance - (a.OpeningBalance + ISNULL(lt.LedgerBalance, 0)) AS Difference
    FROM account.Account AS a
    LEFT JOIN LedgerTotals AS lt ON lt.AccountId = a.AccountId
    WHERE ABS(a.Balance - (a.OpeningBalance + ISNULL(lt.LedgerBalance, 0))) > 0.0001;

    SELECT
        COUNT_BIG(*) AS AccountsChecked,
        SUM(CASE WHEN ABS(a.Balance - (a.OpeningBalance + ISNULL(lt.LedgerBalance, 0))) > 0.0001 THEN 1 ELSE 0 END) AS Mismatches
    FROM account.Account AS a
    LEFT JOIN
    (
        SELECT l.AccountId, SUM(l.Amount) AS LedgerBalance
        FROM account.AccountLedgerEntry AS l
        GROUP BY l.AccountId
    ) AS lt ON lt.AccountId = a.AccountId;
END
GO

CREATE OR ALTER PROCEDURE account.usp_ReconcileTransfers
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        t.TransferId,
        t.RequestId,
        COUNT(l.LedgerEntryId) AS EntryCount,
        SUM(CASE WHEN l.EntryType = 'DEBIT' THEN 1 ELSE 0 END) AS DebitCount,
        SUM(CASE WHEN l.EntryType = 'CREDIT' THEN 1 ELSE 0 END) AS CreditCount,
        ISNULL(SUM(l.Amount), 0) AS NetAmount
    FROM account.Transfer AS t
    LEFT JOIN account.AccountLedgerEntry AS l
      ON l.TransferId = t.TransferId
    GROUP BY t.TransferId, t.RequestId
    HAVING COUNT(l.LedgerEntryId) <> 2
        OR SUM(CASE WHEN l.EntryType = 'DEBIT' THEN 1 ELSE 0 END) <> 1
        OR SUM(CASE WHEN l.EntryType = 'CREDIT' THEN 1 ELSE 0 END) <> 1
        OR ABS(ISNULL(SUM(l.Amount), 0)) > 0.0001;

    SELECT
        COUNT_BIG(*) AS TransfersChecked,
        SUM(CASE WHEN EntryCount <> 2 OR ABS(NetAmount) > 0.0001 THEN 1 ELSE 0 END) AS Mismatches
    FROM
    (
        SELECT
            t.TransferId,
            COUNT(l.LedgerEntryId) AS EntryCount,
            ISNULL(SUM(l.Amount), 0) AS NetAmount
        FROM account.Transfer AS t
        LEFT JOIN account.AccountLedgerEntry AS l
          ON l.TransferId = t.TransferId
        GROUP BY t.TransferId
    ) AS x;
END
GO

PRINT N'Transfer engine and reconciliation procedures created.';
GO
