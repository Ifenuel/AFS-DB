#requires -Version 5.1
<#
.SYNOPSIS
    Show the AFS LocalDB lab: databases, row counts, sample financial rows and backup history.
.DESCRIPTION
    Read-only ADO.NET viewer for the SQL Server 2025 LocalDB fallback. It starts
    MSSQLLocalDB if needed, then prints a compact inventory. Use -Query for your
    own read-only SQL. Do not put passwords in this file.
.EXAMPLE
    .\Show-AfsLocalDb.ps1
.EXAMPLE
    .\Show-AfsLocalDb.ps1 -Database AFS_CoreBanking -Query "SELECT TOP 5 * FROM account.Account;"
#>
[CmdletBinding()]
param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [string]$Database = 'master',
    [string]$Query
)

$ErrorActionPreference = 'Stop'
$localDb = 'C:\Program Files\Microsoft SQL Server\170\Tools\Binn\SqlLocalDB.exe'
if (Test-Path -LiteralPath $localDb) {
    $state = & $localDb info MSSQLLocalDB 2>&1 | Out-String
    if ($state -notmatch 'State:\s+Running') {
        & $localDb start MSSQLLocalDB | Out-Null
    }
}

$connectionString = "Server=$Server;Database=$Database;Integrated Security=true;Connect Timeout=30;Encrypt=false;Application Name=AFS-Show-LocalDB"
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
$connection.Open()

function Write-Query {
    param([string]$Sql)
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = $Sql
    $reader = $command.ExecuteReader()
    do {
        if ($reader.FieldCount -gt 0) {
            $headers = @()
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $headers += $reader.GetName($i) }
            Write-Host ("`n" + ($headers -join ' | '))
            Write-Host (($headers | ForEach-Object { '-' * $_.Length }) -join '-+-')
            while ($reader.Read()) {
                $values = @()
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $values += [string]$reader.GetValue($i)
                }
                Write-Host ($values -join ' | ')
            }
        }
    } while ($reader.NextResult())
    $reader.Close()
    $command.Dispose()
}

try {
    if ($Query) {
        Write-Query -Sql $Query
        return
    }

    Write-Host '=== AFS LocalDB inventory ==='
    Write-Query -Sql @"
SELECT
    CAST(SERVERPROPERTY('Edition') AS varchar(128)) AS Edition,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(64)) AS ProductVersion,
    @@SERVERNAME AS ServerName;
"@
    Write-Query -Sql @"
SELECT name, recovery_model_desc, state_desc, compatibility_level
FROM sys.databases
WHERE name LIKE N'AFS[_]%'
ORDER BY name;
"@
    Write-Query -Sql @"
USE AFS_CoreBanking;
SELECT 'customer.Customer' AS TableName, COUNT_BIG(*) AS [Rows] FROM customer.Customer
UNION ALL SELECT 'account.Account', COUNT_BIG(*) FROM account.Account
UNION ALL SELECT 'account.Transfer', COUNT_BIG(*) FROM account.Transfer
UNION ALL SELECT 'account.AccountLedgerEntry', COUNT_BIG(*) FROM account.AccountLedgerEntry
UNION ALL SELECT 'audit.AuditEvent', COUNT_BIG(*) FROM audit.AuditEvent;
"@
    Write-Query -Sql @"
USE AFS_CoreBanking;
SELECT TOP (10)
    a.AccountId, a.AccountNumber, a.Balance, a.OpeningBalance, s.StatusCode
FROM account.Account AS a
JOIN reference.AccountStatus AS s ON s.AccountStatusId = a.AccountStatusId
ORDER BY a.AccountId;
"@
    Write-Query -Sql @"
USE AFS_Audit;
SELECT TOP (10)
    BackupHistoryId, DatabaseName, BackupType, IsVerified, SizeMB, CompletedAt
FROM operational.BackupHistory
ORDER BY BackupHistoryId DESC;
"@
    Write-Host "`nTo run your own read-only query:"
    Write-Host "  .\Show-AfsLocalDb.ps1 -Database AFS_CoreBanking -Query `"SELECT TOP 5 * FROM account.Transfer;`""
}
finally {
    if ($connection.State -eq 'Open') { $connection.Close() }
    $connection.Dispose()
}
