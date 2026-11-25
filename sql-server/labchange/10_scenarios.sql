/*
  AFS-DBA-001
  P-03 change scenarios. Each is executed by tools/labchange/run_scenarios.py.
  Run against AFS_Lab_Change only.
*/
SET NOCOUNT ON;
USE AFS_Lab_Change;
GO

/* 1. The Clerk-style mistake: an unbounded UPDATE with no WHERE clause. */
CREATE OR ALTER PROCEDURE lab.usp_BadMassUpdate @Multiplier decimal(5,2) = 1.10
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE lab.Account SET Balance = Balance * @Multiplier, UpdatedAt = SYSUTCDATETIME();
    DECLARE @n int = @@ROWCOUNT;
    INSERT INTO lab.ChangeLog (Description, RowsAffected, Outcome)
    VALUES (CONCAT('unbounded balance update x', @Multiplier), @n, 'APPLIED');
    SELECT @n AS rows_affected;
END
GO

/* 2. The same intent, guarded: a transaction plus a row-count assertion.
      A statement that hits more rows than the operator declared is rolled back. */
CREATE OR ALTER PROCEDURE lab.usp_GuardedUpdate
    @Multiplier   decimal(5,2) = 1.10,
    @ExpectedRows int          = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE lab.Account SET Balance = Balance * @Multiplier, UpdatedAt = SYSUTCDATETIME();
        DECLARE @n int = @@ROWCOUNT;
        IF @n <> @ExpectedRows
        BEGIN
            ROLLBACK TRANSACTION;
            INSERT INTO lab.ChangeLog (Description, RowsAffected, Outcome)
            VALUES (CONCAT('guarded update x', @Multiplier), @n, 'ROLLED_BACK');
            THROW 50031, 'row-count guard rejected the change', 1;
        END
        COMMIT TRANSACTION;
        INSERT INTO lab.ChangeLog (Description, RowsAffected, Outcome)
        VALUES (CONCAT('guarded update x', @Multiplier), @n, 'APPLIED');
        SELECT @n AS rows_affected;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* 3. Unsafe migration: adding a NOT NULL column without a default to a
      populated table is rejected by the engine. This is the pre-deployment
      check doing its job, not a bug. */
CREATE OR ALTER PROCEDURE lab.usp_UnsafeMigration
AS
BEGIN
    SET NOCOUNT ON;
    ALTER TABLE lab.Account ADD RiskScore int NOT NULL;
END
GO

/* 4. Corrected migration: nullable, backfill, then enforce NOT NULL. */
CREATE OR ALTER PROCEDURE lab.usp_SafeMigration
AS
BEGIN
    SET NOCOUNT ON;
    /* dynamic SQL: the column does not exist when the procedure is compiled */
    IF COL_LENGTH('lab.Account', 'RiskScore') IS NULL
        EXEC('ALTER TABLE lab.Account ADD RiskScore int NULL;');
    EXEC('UPDATE lab.Account SET RiskScore = 500 WHERE RiskScore IS NULL;');
    EXEC('ALTER TABLE lab.Account ALTER COLUMN RiskScore int NOT NULL;');
    INSERT INTO lab.ChangeLog (Description, RowsAffected, Outcome)
    VALUES ('add RiskScore (nullable, backfill, not null)', 10000, 'APPLIED');
END
GO

/* 5. Detection: compare the live table with the expected invariants. */
CREATE OR ALTER PROCEDURE lab.usp_DetectDrift
    @ExpectedRows  int           = 10000,
    @ExpectedTotal decimal(18,2) = NULL,
    @ExpectedChecksum int        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COUNT(*) AS rows_now, SUM(Balance) AS total_now,
           CHECKSUM_AGG(BINARY_CHECKSUM(AccountId, Balance, Tier)) AS checksum_now,
           CASE WHEN COUNT(*) <> @ExpectedRows THEN 'ROW_COUNT_DRIFT'
                WHEN @ExpectedTotal IS NOT NULL AND SUM(Balance) <> @ExpectedTotal THEN 'BALANCE_DRIFT'
                WHEN @ExpectedChecksum IS NOT NULL
                     AND CHECKSUM_AGG(BINARY_CHECKSUM(AccountId, Balance, Tier)) <> @ExpectedChecksum
                     THEN 'CHECKSUM_DRIFT'
                ELSE 'OK' END AS verdict
    FROM lab.Account;
END
GO

PRINT 'change scenarios ready';
GO
