/*
  AFS-DBA-001
  Purpose: Grow the estate to fixed, checkable totals without breaking the accounting invariant
           Balance = OpeningBalance + SUM(AccountLedgerEntry.Amount).
  Target: 1,000 customers, 1,000 accounts, 20,000 transfers, 40,000 ledger entries,
          2,000 fraud alerts, 500 fraud cases.
  Safety: Idempotent - each block is skipped when its total is already reached. Wrapped in a
          transaction; balances are restated from the ledger, never adjusted by hand.
  Run as: AFS_DBA.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
USE AFS_CoreBanking;
GO

BEGIN TRAN;

------------------------------------------------------------------- customers 562 -> 1,000
DECLARE @haveC int = (SELECT COUNT(*) FROM customer.Customer);
DECLARE @wantC int = 1000 - @haveC;
IF @wantC > 0
BEGIN
    DECLARE @maxC bigint = (SELECT ISNULL(MAX(CustomerId), 0) FROM customer.Customer);
    SET IDENTITY_INSERT customer.Customer ON;
    ;WITH n AS (SELECT TOP (@wantC) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
                FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT customer.Customer (CustomerId, CustomerNumber, FirstName, LastName, Email, Phone,
                              DateOfBirth, RiskRating, CustomerStatus, CreatedAt, UpdatedAt)
    SELECT @maxC + i,
           'C' + RIGHT('000000000' + CAST(@maxC + i AS varchar(9)), 9),
           CHOOSE(1 + (i % 10), N'Ade', N'Chidi', N'Ngozi', N'Folake', N'Emeka', N'Zainab', N'Tunde', N'Amaka', N'Ibrahim', N'Kemi'),
           CHOOSE(1 + ((i * 7) % 10), N'Okafor', N'Adeyemi', N'Balogun', N'Eze', N'Abubakar', N'Oluwole', N'Nwosu', N'Bello', N'Adebayo', N'Ibrahim'),
           LOWER(CHOOSE(1 + (i % 10), N'Ade', N'Chidi', N'Ngozi', N'Folake', N'Emeka', N'Zainab', N'Tunde', N'Amaka', N'Ibrahim', N'Kemi')) + '.' +
           LOWER(CHOOSE(1 + ((i * 7) % 10), N'Okafor', N'Adeyemi', N'Balogun', N'Eze', N'Abubakar', N'Oluwole', N'Nwosu', N'Bello', N'Adebayo', N'Ibrahim')) +
           CAST(@maxC + i AS varchar(9)) + '@afs.example',
           '+234' + RIGHT('0000000000' + CAST(7000000000 + ((i * 37) % 199999999) AS varchar(10)), 10),
           DATEADD(day, -((18 * 365) + ((i * 29) % 19000)), CAST('2026-06-01' AS date)),
           CHOOSE(1 + (i % 5), 'LOW', 'LOW', 'MEDIUM', 'LOW', 'HIGH'),
           'ACTIVE', DATEADD(day, -((i * 11) % 700), SYSUTCDATETIME()), SYSUTCDATETIME()
    FROM n;
    PRINT 'customers added: ' + CAST(@@ROWCOUNT AS varchar(10));
    SET IDENTITY_INSERT customer.Customer OFF;
END

------------------------------------------------------------------- addresses, one per new customer
DECLARE @maxA bigint = (SELECT ISNULL(MAX(AddressId), 0) FROM customer.CustomerAddress);
SET IDENTITY_INSERT customer.CustomerAddress ON;
;WITH newc AS (
    SELECT c.CustomerId, ROW_NUMBER() OVER (ORDER BY c.CustomerId) AS i
    FROM customer.Customer c
    WHERE NOT EXISTS (SELECT 1 FROM customer.CustomerAddress a WHERE a.CustomerId = c.CustomerId)
)
INSERT customer.CustomerAddress (AddressId, CustomerId, AddressType, Line1, Line2, City, Region, PostalCode, CountryCode, IsPrimary, CreatedAt)
SELECT @maxA + i, CustomerId,
       CASE WHEN i % 4 = 0 THEN 'WORK' ELSE 'HOME' END,
       CAST(1 + (i % 240) AS nvarchar(10)) + N' ' + CHOOSE(1 + (i % 8), N'Marina Road', N'Awolowo Way', N'Ahmadu Bello Way', N'Ring Road', N'Opebi Link Road', N'Aba Road', N'Asokoro Avenue', N'Allen Avenue'),
       NULL,
       CHOOSE(1 + (i % 8), N'Lagos', N'Ibadan', N'Abuja', N'Ilorin', N'Lekki', N'Port Harcourt', N'Kano', N'Enugu'),
       CHOOSE(1 + (i % 6), N'Lagos', N'Oyo', N'FCT', N'Kwara', N'Lagos', N'Rivers'),
       '1000' + CAST(100 + (i % 800) AS varchar(4)),
       'NG', 1, DATEADD(day, -((i * 5) % 600), SYSUTCDATETIME())
FROM newc;
SET IDENTITY_INSERT customer.CustomerAddress OFF;

------------------------------------------------------------------- contacts, two per new customer
DECLARE @maxK bigint = (SELECT ISNULL(MAX(ContactId), 0) FROM customer.CustomerContact);
SET IDENTITY_INSERT customer.CustomerContact ON;
;WITH newc AS (
    SELECT c.CustomerId, ISNULL(c.Phone, '+2347000000000') AS Phone, ISNULL(c.Email, 'x@afs.example') AS Email,
           ROW_NUMBER() OVER (ORDER BY c.CustomerId) AS i
    FROM customer.Customer c
    WHERE NOT EXISTS (SELECT 1 FROM customer.CustomerContact k WHERE k.CustomerId = c.CustomerId)
)
INSERT customer.CustomerContact (ContactId, CustomerId, ContactType, ContactValue, IsPrimary, CreatedAt)
SELECT @maxK + (i * 2) - 1, CustomerId, 'PHONE', Phone, 1, SYSUTCDATETIME() FROM newc
UNION ALL
SELECT @maxK + (i * 2), CustomerId, 'EMAIL', Email, 1, SYSUTCDATETIME() FROM newc;
SET IDENTITY_INSERT customer.CustomerContact OFF;

------------------------------------------------------------------- accounts 725 -> 1,000
DECLARE @haveA int = (SELECT COUNT(*) FROM account.Account);
DECLARE @wantA int = 1000 - @haveA;
IF @wantA > 0
BEGIN
    DECLARE @maxAcc bigint = (SELECT ISNULL(MAX(AccountId), 0) FROM account.Account);
    SET IDENTITY_INSERT account.Account ON;
    ;WITH pick AS (
        SELECT c.CustomerId, ROW_NUMBER() OVER (ORDER BY c.CustomerId DESC) AS i
        FROM customer.Customer c
        WHERE NOT EXISTS (SELECT 1 FROM account.Account a WHERE a.CustomerId = c.CustomerId)
    ), n AS (SELECT TOP (@wantA) * FROM pick ORDER BY i)
    INSERT account.Account (AccountId, AccountNumber, CustomerId, AccountTypeId, AccountStatusId,
                            CurrencyCode, Balance, OpeningBalance, OverdraftLimit, PerTransferLimit,
                            DailyTransferLimit, OpenedAt, UpdatedAt)
    SELECT @maxAcc + i,
           'ACC' + RIGHT('000000000' + CAST(@maxAcc + i AS varchar(9)), 9),
           CustomerId,
           1 + (i % 4),
           CASE WHEN i % 17 = 0 THEN 2 ELSE 1 END,
           CHOOSE(1 + (i % 5), 'NGN', 'NGN', 'USD', 'GBP', 'EUR'),
           CAST(5000 + ((i * 137) % 480000) AS decimal(18,2)),
           CAST(5000 + ((i * 137) % 480000) AS decimal(18,2)),
           0, 50000, 200000,
           DATEADD(day, -((i * 13) % 900), SYSUTCDATETIME()), SYSUTCDATETIME()
    FROM n;
    PRINT 'accounts added: ' + CAST(@@ROWCOUNT AS varchar(10));
    SET IDENTITY_INSERT account.Account OFF;
END

COMMIT;
GO

------------------------------------------------------------------- transfers 17,372 -> 20,000, ledger to 40,000
BEGIN TRAN;

DECLARE @haveT int = (SELECT COUNT(*) FROM account.Transfer);
DECLARE @wantT int = 20000 - @haveT;

IF @wantT > 0
BEGIN
    CREATE TABLE #t (
        i int IDENTITY(1,1) PRIMARY KEY,
        TransferId uniqueidentifier NOT NULL,
        RequestId uniqueidentifier NOT NULL,
        FromAccountId bigint NOT NULL,
        ToAccountId bigint NOT NULL,
        Amount decimal(18,2) NOT NULL,
        CurrencyCode char(3) NOT NULL,
        CreatedAt datetime2 NOT NULL,
        CompletedAt datetime2 NOT NULL
    );

    ;WITH acct AS (
        SELECT AccountId, CurrencyCode, Balance, ROW_NUMBER() OVER (ORDER BY AccountId) AS rn,
               COUNT(*) OVER () AS total
        FROM account.Account WHERE AccountStatusId = 1 AND Balance >= 1000
    ), n AS (SELECT TOP (@wantT) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
             FROM sys.all_objects a CROSS JOIN sys.all_objects b),
    pairs AS (
        SELECT n.i, f.AccountId AS FromAccountId, f.Balance AS FromBalance, f.CurrencyCode,
               t.AccountId AS ToAccountId,
               DATEADD(day, -((n.i * 3) % 300), DATEADD(minute, (n.i * 17) % 1440, CAST('2026-06-01' AS datetime2))) AS dt
        FROM n
        CROSS APPLY (SELECT total FROM acct WHERE rn = 1) tot
        JOIN acct f ON f.rn = 1 + (n.i % tot.total)
        JOIN acct t ON t.rn = 1 + (((n.i * 7) + 3) % tot.total)
        WHERE f.AccountId <> t.AccountId
    )
    INSERT #t (TransferId, RequestId, FromAccountId, ToAccountId, Amount, CurrencyCode, CreatedAt, CompletedAt)
    SELECT NEWID(), NEWID(), q.FromAccountId, q.ToAccountId,
           CAST(CASE WHEN q.base < q.cap THEN q.base ELSE q.cap END AS decimal(18,2)),
           q.CurrencyCode, q.dt, DATEADD(second, 1 + (q.i % 9), q.dt)
    FROM (
        SELECT p.*,
               250 + ((p.i * 97) % 19750) AS base,
               (p.FromBalance * 0.40) / COUNT(*) OVER (PARTITION BY p.FromAccountId) AS cap
        FROM pairs p
    ) q;

    INSERT account.Transfer (TransferId, RequestId, FromAccountId, ToAccountId, Amount, CurrencyCode,
                             Status, Description, CorrelationId, CreatedAt, CompletedAt)
    SELECT TransferId, RequestId, FromAccountId, ToAccountId, Amount, CurrencyCode,
           'COMPLETED', 'Loaded transfer ' + CAST(i AS varchar(10)), NEWID(), CreatedAt, CompletedAt
    FROM #t;

    DECLARE @maxL bigint = (SELECT ISNULL(MAX(LedgerEntryId), 0) FROM account.AccountLedgerEntry);
    SET IDENTITY_INSERT account.AccountLedgerEntry ON;
    INSERT account.AccountLedgerEntry (LedgerEntryId, TransferId, AccountId, EntryType, Amount,
                                       BalanceAfter, CurrencyCode, OccurredAt, Description)
    SELECT @maxL + (i * 2) - 1, TransferId, FromAccountId, 'DEBIT', -Amount, 0, CurrencyCode, CompletedAt, 'Transfer out'
    FROM #t
    UNION ALL
    SELECT @maxL + (i * 2), TransferId, ToAccountId, 'CREDIT', Amount, 0, CurrencyCode, CompletedAt, 'Transfer in'
    FROM #t;
    SET IDENTITY_INSERT account.AccountLedgerEntry OFF;

    DECLARE @maxE bigint = (SELECT ISNULL(MAX(TransferEventId), 0) FROM account.TransferEvent);
    SET IDENTITY_INSERT account.TransferEvent ON;
    INSERT account.TransferEvent (TransferEventId, TransferId, EventType, EventData, Actor, CreatedAt)
    SELECT @maxE + i, TransferId, 'COMPLETED', '{"source":"dataset-load"}', 'system.load', CompletedAt
    FROM #t;
    SET IDENTITY_INSERT account.TransferEvent OFF;

    -- Restate balances from the ledger itself, so the invariant holds by construction.
    UPDATE a
       SET Balance = a.OpeningBalance + ISNULL(x.s, 0), UpdatedAt = SYSUTCDATETIME()
      FROM account.Account a
      LEFT JOIN (SELECT AccountId, SUM(Amount) AS s FROM account.AccountLedgerEntry GROUP BY AccountId) x
        ON x.AccountId = a.AccountId
     WHERE a.AccountId IN (SELECT FromAccountId FROM #t UNION SELECT ToAccountId FROM #t);

    -- BalanceAfter is the running balance at each entry, across the whole history.
    ;WITH bal AS (
        SELECT l.LedgerEntryId,
               a.OpeningBalance + SUM(l.Amount) OVER (PARTITION BY l.AccountId
                   ORDER BY l.OccurredAt, l.LedgerEntryId ROWS UNBOUNDED PRECEDING) AS running
        FROM account.AccountLedgerEntry l
        JOIN account.Account a ON a.AccountId = l.AccountId
    )
    UPDATE l SET BalanceAfter = b.running
    FROM account.AccountLedgerEntry l JOIN bal b ON b.LedgerEntryId = l.LedgerEntryId;

    PRINT 'transfers added: ' + CAST(@wantT AS varchar(10));
    DROP TABLE #t;
END

COMMIT;
GO

------------------------------------------------------------------- fraud: alerts 2,000, cases 500
USE AFS_Fraud;
GO
BEGIN TRAN;

DECLARE @haveF int = (SELECT COUNT(*) FROM fraud.FraudAlert);
DECLARE @wantF int = 2000 - @haveF;
IF @wantF > 0
BEGIN
    DECLARE @maxF bigint = (SELECT ISNULL(MAX(FraudAlertId), 0) FROM fraud.FraudAlert);
    SET IDENTITY_INSERT fraud.FraudAlert ON;
    ;WITH src AS (
        SELECT TOP (@wantF)
               t.TransferId, t.FromAccountId, t.Amount, t.CreatedAt,
               a.CustomerId,
               ROW_NUMBER() OVER (ORDER BY NEWID()) AS i
        FROM AFS_CoreBanking.account.Transfer t
        JOIN AFS_CoreBanking.account.Account a ON a.AccountId = t.FromAccountId
        ORDER BY NEWID()
    )
    INSERT fraud.FraudAlert (FraudAlertId, FraudRuleId, TransferId, AccountId, CustomerId, Amount,
                             Status, Details, CreatedAt, ResolvedAt)
    SELECT @maxF + i, 1 + (i % 3), TransferId, FromAccountId, CustomerId, Amount,
           CHOOSE(1 + (i % 4), 'OPEN', 'IN_REVIEW', 'CLOSED_CONFIRMED', 'CLOSED_FALSE_POSITIVE'),
           'Rule ' + CAST(1 + (i % 3) AS varchar(2)) + ' matched: ' +
           CHOOSE(1 + (i % 3), 'amount above threshold', 'velocity in window', 'new beneficiary'),
           DATEADD(minute, 5, CreatedAt),
           CASE WHEN i % 4 >= 2 THEN DATEADD(hour, 6 + (i % 40), CreatedAt) ELSE NULL END
    FROM src;
    PRINT 'fraud alerts added: ' + CAST(@@ROWCOUNT AS varchar(10));
    SET IDENTITY_INSERT fraud.FraudAlert OFF;
END

DECLARE @haveFC int = (SELECT COUNT(*) FROM fraud.FraudCase);
DECLARE @wantFC int = 500 - @haveFC;
IF @wantFC > 0
BEGIN
    DECLARE @maxC2 bigint = (SELECT ISNULL(MAX(FraudCaseId), 0) FROM fraud.FraudCase);
    SET IDENTITY_INSERT fraud.FraudCase ON;
    ;WITH src AS (
        SELECT TOP (@wantFC) f.FraudAlertId, f.CreatedAt,
               ROW_NUMBER() OVER (ORDER BY f.FraudAlertId) AS i
        FROM fraud.FraudAlert f
        WHERE NOT EXISTS (SELECT 1 FROM fraud.FraudCase c WHERE c.FraudAlertId = f.FraudAlertId)
          AND f.Status <> 'OPEN'
        ORDER BY f.FraudAlertId DESC
    )
    INSERT fraud.FraudCase (FraudCaseId, FraudAlertId, Investigator, Status, Findings, OpenedAt, ClosedAt)
    SELECT @maxC2 + i, FraudAlertId,
           CHOOSE(1 + (i % 6), N'A. Bello', N'C. Okafor', N'D. Musa', N'E. Adeyemi', N'F. Nwosu', N'G. Ibrahim'),
           CHOOSE(1 + (i % 3), 'CLOSED', 'CLOSED', 'INVESTIGATING'),
           CHOOSE(1 + (i % 3), N'Customer confirmed the transfer after callback.', N'Beneficiary added 11 minutes before the transfer.', N'Repeat pattern across three accounts.'),
           DATEADD(hour, 2, CreatedAt),
           CASE WHEN i % 3 <> 2 THEN DATEADD(day, 1 + (i % 9), CreatedAt) ELSE NULL END
    FROM src;
    PRINT 'fraud cases added: ' + CAST(@@ROWCOUNT AS varchar(10));
    SET IDENTITY_INSERT fraud.FraudCase OFF;
END

COMMIT;
GO

------------------------------------------------------------------- verify
SET NOCOUNT ON;
SELECT 'customers' AS metric, COUNT(*) AS value FROM AFS_CoreBanking.customer.Customer
UNION ALL SELECT 'accounts', COUNT(*) FROM AFS_CoreBanking.account.Account
UNION ALL SELECT 'transfers', COUNT(*) FROM AFS_CoreBanking.account.Transfer
UNION ALL SELECT 'ledger entries', COUNT(*) FROM AFS_CoreBanking.account.AccountLedgerEntry
UNION ALL SELECT 'fraud alerts', COUNT(*) FROM AFS_Fraud.fraud.FraudAlert
UNION ALL SELECT 'fraud cases', COUNT(*) FROM AFS_Fraud.fraud.FraudCase;
GO

SELECT COUNT(*) AS balance_mismatches
FROM (
    SELECT a.AccountId
    FROM AFS_CoreBanking.account.Account a
    LEFT JOIN AFS_CoreBanking.account.AccountLedgerEntry l ON l.AccountId = a.AccountId
    GROUP BY a.AccountId, a.Balance, a.OpeningBalance
    HAVING ABS(a.Balance - (a.OpeningBalance + ISNULL(SUM(l.Amount), 0))) > 0.0001
) x;
GO
