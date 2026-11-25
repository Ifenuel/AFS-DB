/* Host-loss drill: rebuild the estate on a different engine instance.
   Target is (localdb)\MSSQLLocalDB, a separate SQL Server 2025 instance with no
   shared configuration, logins or data files with the primary instance.
   Success means: restore completes, row counts match, invariant still holds. */
SET NOCOUNT ON;

DECLARE @t0 datetime2(3) = SYSDATETIME(), @t1 datetime2(3);
DECLARE @data nvarchar(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400));
DECLARE @sql nvarchar(max);

PRINT 'instance   : ' + CAST(SERVERPROPERTY('ServerName') AS nvarchar(200));
PRINT 'version    : ' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50));
PRINT 'data dir   : ' + @data;
PRINT 'backup     : C:\ProgramData\AFS\backups\full\AFS_CoreBanking_20261125_072930.bak';

IF DB_ID('AFS_HostLoss') IS NOT NULL
BEGIN
    ALTER DATABASE AFS_HostLoss SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AFS_HostLoss;
    PRINT 'removed    : prior AFS_HostLoss';
END

SET @sql = N'RESTORE DATABASE AFS_HostLoss FROM DISK = N''C:\ProgramData\AFS\backups\full\AFS_CoreBanking_20261125_072930.bak'''
         + N' WITH MOVE N''AFS_CoreBanking'' TO N''' + @data + N'AFS_HostLoss.mdf'','
         + N' MOVE N''AFS_CoreBanking_log'' TO N''' + @data + N'AFS_HostLoss_log.ldf'','
         + N' RECOVERY, STATS = 20;';
EXEC (@sql);

SET @t1 = SYSDATETIME();
PRINT 'restore s  : ' + CAST(DATEDIFF(millisecond, @t0, @t1) / 1000.0 AS varchar(20));
PRINT 'state      : ' + CAST(DATABASEPROPERTYEX('AFS_HostLoss', 'Status') AS varchar(30));
PRINT 'files      : ' + @data + N'AFS_HostLoss.mdf';
SELECT CAST(SUM(size) * 8.0 / 1024 AS decimal(10,1)) AS size_mb
FROM AFS_HostLoss.sys.database_files;
GO

/* Row counts must equal the source estate. */
SELECT 'customer.Customer' AS object_name, COUNT_BIG(*) AS rows_after_restore
FROM AFS_HostLoss.customer.Customer
UNION ALL SELECT 'account.Account', COUNT_BIG(*) FROM AFS_HostLoss.account.Account
UNION ALL SELECT 'account.Transfer', COUNT_BIG(*) FROM AFS_HostLoss.account.Transfer
UNION ALL SELECT 'account.AccountLedgerEntry', COUNT_BIG(*) FROM AFS_HostLoss.account.AccountLedgerEntry
UNION ALL SELECT 'account.TransferEvent', COUNT_BIG(*) FROM AFS_HostLoss.account.TransferEvent

UNION ALL SELECT 'audit.AuditEvent', COUNT_BIG(*) FROM AFS_HostLoss.audit.AuditEvent;
GO

/* Invariant on the rebuilt copy: every balance equals opening + posted ledger. */
SELECT COUNT_BIG(*) AS balance_mismatches
FROM AFS_HostLoss.account.Account a
CROSS APPLY (
    SELECT SUM(l.Amount) AS delta
    FROM AFS_HostLoss.account.AccountLedgerEntry l
    WHERE l.AccountId = a.AccountId
) x
WHERE a.Balance <> a.OpeningBalance + ISNULL(x.delta, 0);
GO
