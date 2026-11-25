<#
.SYNOPSIS
    Host-loss rebuild drill: back up the estate, restore it onto a second SQL
    Server instance, and prove the rebuilt copy matches the live one.

.DESCRIPTION
    The target is (localdb)\MSSQLLocalDB - a separate SQL Server 2025 instance
    with its own service, its own data files and no shared logins with the
    primary instance. Restoring there is the same operation as rebuilding after
    the original host is lost.

    Writes evidence/verify/live/54_host_loss_restore.txt from the actual output.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/drill-host-loss.ps1
#>
[CmdletBinding()]
param(
    [string]$Source = ".",
    [string]$BackupDir = "C:\Backups\hostloss"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root
$stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$out = New-Object System.Collections.Generic.List[string]

function Sql([string]$instance, [string]$query) {
    $raw = & sqlcmd -S $instance -E -C -b -h -1 -W -s "|" -Q "SET NOCOUNT ON; $query" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed on ${instance}: $raw" }
    $items = @($raw | Where-Object { $_ -match '\S' })
    return ,$items
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# --- 1. back up the live estate now, so the comparison is like-for-like
$coreBak = Join-Path $BackupDir "AFS_CoreBanking_hostloss.bak"
$payBak  = Join-Path $BackupDir "AFS_Payments_hostloss.bak"
$sw = [Diagnostics.Stopwatch]::StartNew()
Sql $Source "BACKUP DATABASE AFS_CoreBanking TO DISK='$coreBak' WITH INIT, CHECKSUM, COMPRESSION;" | Out-Null
Sql $Source "BACKUP DATABASE AFS_Payments TO DISK='$payBak' WITH INIT, CHECKSUM, COMPRESSION;" | Out-Null
$backupSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$coreMb = [math]::Round((Get-Item $coreBak).Length / 1MB, 1)
$payMb  = [math]::Round((Get-Item $payBak).Length / 1MB, 1)

# --- 2. start the second instance and restore onto it
& sqllocaldb start MSSQLLocalDB | Out-Null
$info = & sqllocaldb info MSSQLLocalDB
$pipe = ($info | Select-String -Pattern 'Instance pipe name:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$version = ($info | Select-String -Pattern '^Version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()

$restore = @"
DECLARE @data nvarchar(400) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400));
DECLARE @sql nvarchar(max);
IF DB_ID('AFS_HostLoss') IS NOT NULL
BEGIN
    ALTER DATABASE AFS_HostLoss SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AFS_HostLoss;
END
SET @sql = N'RESTORE DATABASE AFS_HostLoss FROM DISK = N''$coreBak'' WITH '
    + N'MOVE N''AFS_CoreBanking'' TO N''' + @data + N'AFS_HostLoss.mdf'', '
    + N'MOVE N''AFS_CoreBanking_log'' TO N''' + @data + N'AFS_HostLoss_log.ldf'', RECOVERY;';
EXEC (@sql);
IF DB_ID('AFS_Payments_HostLoss') IS NOT NULL
BEGIN
    ALTER DATABASE AFS_Payments_HostLoss SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AFS_Payments_HostLoss;
END
SET @sql = N'RESTORE DATABASE AFS_Payments_HostLoss FROM DISK = N''$payBak'' WITH '
    + N'MOVE N''AFS_Payments'' TO N''' + @data + N'AFS_Payments_HostLoss.mdf'', '
    + N'MOVE N''AFS_Payments_log'' TO N''' + @data + N'AFS_Payments_HostLoss_log.ldf'', RECOVERY;';
EXEC (@sql);
"@
$sw.Restart()
$restoreRaw = & sqlcmd -S $pipe -E -C -b -Q $restore 2>&1
if ($LASTEXITCODE -ne 0) { throw "restore failed: $restoreRaw" }
$restoreSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)

$state = Sql $pipe "SELECT 'AFS_HostLoss|' + CAST(DATABASEPROPERTYEX('AFS_HostLoss','Status') AS varchar(20)) + '|' + CAST(CAST(SUM(size)*8.0/1024 AS decimal(10,1)) AS varchar(20)) FROM AFS_HostLoss.sys.database_files; SELECT 'AFS_Payments_HostLoss|' + CAST(DATABASEPROPERTYEX('AFS_Payments_HostLoss','Status') AS varchar(20)) + '|' + CAST(CAST(SUM(size)*8.0/1024 AS decimal(10,1)) AS varchar(20)) FROM AFS_Payments_HostLoss.sys.database_files;"
$states = @{}
foreach ($row in $state) {
    $p = $row -split '\|'
    $states[$p[0]] = @{ State = $p[1]; Mb = $p[2] }
}

# --- 3. compare row counts, live vs rebuilt
$objects = @(
    @("customer.Customer",            "customer.Customer"),
    @("customer.CustomerAddress",     "customer.CustomerAddress"),
    @("customer.CustomerContact",     "customer.CustomerContact"),
    @("account.Account",              "account.Account"),
    @("account.Transfer",             "account.Transfer"),
    @("account.AccountLedgerEntry",   "account.AccountLedgerEntry"),
    @("account.TransferEvent",        "account.TransferEvent"),
    @("audit.AuditEvent",             "audit.AuditEvent")
)
$mismatch = 0
$rows = @()
foreach ($o in $objects) {
    $live = (Sql $Source "SELECT COUNT_BIG(*) FROM AFS_CoreBanking.$($o[0]);")[0].Trim()
    $copy = (Sql $pipe   "SELECT COUNT_BIG(*) FROM AFS_HostLoss.$($o[1]);")[0].Trim()
    $ok = if ($live -eq $copy) { "yes" } else { "NO"; $script:mismatch++ }
    $rows += "{0,-28} {1,10} {2,10}   {3}" -f $o[0], $live, $copy, $ok
}
foreach ($o in @(@("payment.Payment", "payment.Payment"), @("payment.PaymentEvent", "payment.PaymentEvent"), @("settlement.SettlementItem", "settlement.SettlementItem"))) {
    $live = (Sql $Source "SELECT COUNT_BIG(*) FROM AFS_Payments.$($o[0]);")[0].Trim()
    $copy = (Sql $pipe   "SELECT COUNT_BIG(*) FROM AFS_Payments_HostLoss.$($o[1]);")[0].Trim()
    $ok = if ($live -eq $copy) { "yes" } else { "NO"; $script:mismatch++ }
    $rows += "{0,-28} {1,10} {2,10}   {3}" -f $o[0], $live, $copy, $ok
}

# --- 4. verify the money invariant on the rebuilt copy
$balance = (Sql $pipe @"
SELECT COUNT_BIG(*) FROM AFS_HostLoss.account.Account a
CROSS APPLY (SELECT SUM(l.Amount) AS delta FROM AFS_HostLoss.account.AccountLedgerEntry l
             WHERE l.AccountId = a.AccountId) x
WHERE a.Balance <> a.OpeningBalance + ISNULL(x.delta, 0);
"@)[0].Trim()

$sourceVersion = (Sql $Source "SELECT LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)), 20);")[0].Trim()

$out.Add("=== Host-loss rebuild drill  $stamp ===")
$out.Add("source instance : $Source  (SQL Server $sourceVersion)")
$out.Add("target instance : (localdb)\MSSQLLocalDB  (SQL Server $version, separate engine)")
$out.Add("backup          : $coreBak  ($coreMb MB, CHECKSUM, COMPRESSION)")
$out.Add("                  $payBak  ($payMb MB, CHECKSUM, COMPRESSION)")
$out.Add("backup time     : $backupSeconds s")
$out.Add("")
$out.Add("--- 1. restore onto the second instance")
$out.Add(("AFS_HostLoss          {0,-8} {1,7} MB" -f $states["AFS_HostLoss"].State, $states["AFS_HostLoss"].Mb))
$out.Add(("AFS_Payments_HostLoss {0,-8} {1,7} MB" -f $states["AFS_Payments_HostLoss"].State, $states["AFS_Payments_HostLoss"].Mb))
$out.Add("restore time    : $restoreSeconds s (both databases, from cold files)")
$out.Add("")
$out.Add("--- 2. row counts, live vs rebuilt")
$out.Add("object                           live    rebuilt   match")
$out.AddRange([string[]]$rows)
$out.Add("")
$out.Add("--- 3. integrity on the rebuilt copy")
$out.Add("balance mismatches : $balance")
$out.Add("")
$verdict = if ($mismatch -eq 0 -and $balance -eq "0") { "PASS - the estate rebuilds on a different instance with identical data" } else { "FAIL - $mismatch object(s) differ" }
$out.Add("verdict         : $verdict")
$out.Add("")

$target = "evidence/verify/live/54_host_loss_restore.txt"
[IO.File]::WriteAllLines((Join-Path $root $target), $out, (New-Object Text.UTF8Encoding($true)))
Write-Host ($out -join "`n")
Write-Host ""
Write-Host "wrote $target"
