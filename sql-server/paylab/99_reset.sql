/* AFS-DBA-001
   Reset the P-01 laboratory to a clean, deterministic state.
   Deletes lab rows only. Portfolio tables in AFS_Payments are never touched.
   @DropIdempotencyIndex = 1 returns the schema to the pre-fix baseline. */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
USE AFS_Payments;
GO

CREATE OR ALTER PROCEDURE paylab.usp_Reset
    @DropIdempotencyIndex bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM paylab.ReconBreak;
    DELETE FROM paylab.ReconRun;
    DELETE FROM paylab.ExceptionQueue;
    DELETE FROM paylab.Inbox;
    DELETE FROM paylab.Outbox;
    DELETE FROM paylab.PaymentEvent;
    DELETE FROM paylab.LedgerEntry;
    DELETE FROM paylab.PaymentIntent;
    DELETE FROM paylab.FaultLog;
    DELETE FROM paylab.ScenarioRun;

    DELETE FROM paylab.Account;
    DBCC CHECKIDENT ('paylab.Account', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.PaymentIntent', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.LedgerEntry', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.PaymentEvent', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.ReconRun', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.ReconBreak', RESEED, 0) WITH NO_INFOMSGS;
    DBCC CHECKIDENT ('paylab.Outbox', RESEED, 0) WITH NO_INFOMSGS;

    WITH n AS (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
    INSERT INTO paylab.Account (AccountNumber, CustomerName, CurrencyCode, OpeningBalance, Balance)
    SELECT 'PAYLAB' + RIGHT('000000' + CAST(i AS varchar(6)), 6),
           N'Synthetic Customer ' + CAST(i AS varchar(6)),
           'NGN', 10000.0000, 10000.0000
    FROM n;

    IF @DropIdempotencyIndex = 1
       AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_paylab_Intent_Idempotency')
        DROP INDEX UX_paylab_Intent_Idempotency ON paylab.PaymentIntent;

    SELECT COUNT(*) AS accounts, SUM(Balance) AS total_balance FROM paylab.Account;
END
GO

EXEC paylab.usp_Reset @DropIdempotencyIndex = 0;
GO
PRINT 'paylab reset';
GO
