/* Warm-standby drill: a second instance receives the same backup stream, stays
   in RESTORING state (readable only for recovery), and is brought online as a
   manual failover. This measures the recovery point and recovery time rather
   than assuming them. */
SET NOCOUNT ON;

DECLARE @data nvarchar(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400));
DECLARE @sql nvarchar(max);
DECLARE @t0 datetime2(3), @t1 datetime2(3);

PRINT 'instance   : ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar(200));
PRINT 'version    : ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50));

IF DB_ID('AFS_Standby') IS NOT NULL
BEGIN
    ALTER DATABASE AFS_Standby SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AFS_Standby;
    PRINT 'reset      : prior AFS_Standby dropped';
END

SET @t0 = SYSDATETIME();
SET @sql = N'RESTORE DATABASE AFS_Standby FROM DISK = N''C:\Backups\hostloss\standby_full.bak'' WITH '
         + N'MOVE N''AFS_CoreBanking'' TO N''' + @data + N'AFS_Standby.mdf'', '
         + N'MOVE N''AFS_CoreBanking_log'' TO N''' + @data + N'AFS_Standby_log.ldf'', NORECOVERY;';
EXEC (@sql);
PRINT 'standby    : full restore with NORECOVERY (not readable, ready to receive logs)';
PRINT 'state      : ' + CAST(DATABASEPROPERTYEX('AFS_Standby', 'Status') AS varchar(30))
    + ' / IsInStandBy=' + CAST(DATABASEPROPERTYEX('AFS_Standby', 'IsInStandBy') AS varchar(5));

RESTORE LOG AFS_Standby FROM DISK = 'C:\Backups\hostloss\standby_log.trn' WITH NORECOVERY;
PRINT 'standby    : log restored with NORECOVERY, last log applied';

SET @t1 = SYSDATETIME();
PRINT 'standby s  : ' + CAST(DATEDIFF(millisecond, @t0, @t1) / 1000.0 AS varchar(20));

/* Failover: bring the standby online and read it as the new primary. */
SET @t0 = SYSDATETIME();
RESTORE DATABASE AFS_Standby WITH RECOVERY;
SET @t1 = SYSDATETIME();
PRINT 'failover s : ' + CAST(DATEDIFF(millisecond, @t0, @t1) / 1000.0 AS varchar(20));
PRINT 'state      : ' + CAST(DATABASEPROPERTYEX('AFS_Standby', 'Status') AS varchar(30));
GO

SELECT 'customer.Customer' AS object_name, COUNT_BIG(*) AS rows_on_standby
FROM AFS_Standby.customer.Customer
UNION ALL SELECT 'account.Account', COUNT_BIG(*) FROM AFS_Standby.account.Account
UNION ALL SELECT 'account.Transfer', COUNT_BIG(*) FROM AFS_Standby.account.Transfer
UNION ALL SELECT 'account.AccountLedgerEntry', COUNT_BIG(*) FROM AFS_Standby.account.AccountLedgerEntry;
GO

SELECT COUNT_BIG(*) AS balance_mismatches
FROM AFS_Standby.account.Account a
CROSS APPLY (SELECT SUM(l.Amount) AS delta FROM AFS_Standby.account.AccountLedgerEntry l
             WHERE l.AccountId = a.AccountId) x
WHERE a.Balance <> a.OpeningBalance + ISNULL(x.delta, 0);
GO
