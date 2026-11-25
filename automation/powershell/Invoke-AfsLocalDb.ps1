#requires -Version 5.1
<#
.SYNOPSIS
    Execute the AFS SQL scripts against a LocalDB instance using ADO.NET.

.DESCRIPTION
    LocalDB is a user-mode SQL Server engine. The installed go-sqlcmd client
    cannot resolve the (localdb) instance name on this host, so this runner uses
    System.Data.SqlClient, splits scripts on GO, substitutes the same sqlcmd
    variables used by the deployment wrapper, and keeps one connection so
    session-scoped #temp tables survive across batches.

    This is a verification fallback, not the full Developer instance. It skips
    server logins and server audit because LocalDB does not provide them; the
    security users are created WITHOUT LOGIN so the permission tests can run.
#>
[CmdletBinding()]
param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [string]$DataRoot = 'C:\AFS\Data',
    [string]$LogRoot = 'C:\AFS\Log',
    [string]$BackupRoot = 'C:\AFS\Backups',
    [string]$AuditRoot = 'C:\AFS\Audit',
    [switch]$SkipTests,
    [switch]$Exercises
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path $repoRoot 'logs'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logFile = Join-Path $logDir "localdb-run-$stamp.log"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$variables = @{
    DataRoot = $DataRoot
    LogRoot = $LogRoot
    BackupRoot = $BackupRoot
    AuditRoot = $AuditRoot
    DatabaseName = 'AFS_CoreBanking'
    BackupFile = ''
    StopAt = ''
    IsLog = '0'
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('s'), $Message
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line
}

foreach ($directory in @($DataRoot, $LogRoot, $BackupRoot, $AuditRoot)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$connectionString = "Server=$Server;Integrated Security=true;Connect Timeout=60;Encrypt=false;MultipleActiveResultSets=true;Application Name=AFS-LocalDB-Runner"
$infoHandler = [System.Data.SqlClient.SqlInfoMessageEventHandler]{
    param($sender, $eventArgs)
    foreach ($message in $eventArgs.Errors) {
        Write-Host ("  {0}: {1}" -f $message.Number, $message.Message)
        Add-Content -LiteralPath $logFile -Value ("  {0}: {1}" -f $message.Number, $message.Message)
    }
}

function Expand-SqlVariables {
    param([string]$Text)
    foreach ($key in $variables.Keys) {
        $Text = $Text.Replace('$(' + $key + ')', [string]$variables[$key])
    }
    return $Text
}

function Invoke-SqlFile {
    param(
        [string]$RelativePath,
        [switch]$LocalDbSecurity,
        [switch]$DisableOnlineIndex,
        [switch]$LocalDbBackup
    )

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "SQL script not found: $path"
    }

    $content = Get-Content -LiteralPath $path -Raw
    $content = Expand-SqlVariables -Text $content
    if ($LocalDbSecurity) {
        # LocalDB supports database users but not SQL logins. Keep the same
        # role and permission grants while creating loginless users for the
        # permission tests.
        $content = $content -replace 'CREATE USER \[([^\]]+)\] FOR LOGIN \[[^\]]+\]', 'CREATE USER [$1] WITHOUT LOGIN'
    }
    if ($DisableOnlineIndex) {
        # Online index build is an Enterprise/Developer feature. LocalDB is
        # Express-based; run the same index change offline for this fallback.
        $content = $content -replace 'ONLINE\s*=\s*ON', 'ONLINE = OFF'
    }
    if ($LocalDbBackup) {
        # Backup compression is not available on Express Edition. Keep the
        # CHECKSUM and verification steps; only remove COMPRESSION.
        $content = $content -replace 'COMPRESSION,\s*', ''
        $content = $content -replace ',\s*COMPRESSION', ''
    }

    $batches = [regex]::Split($content, '(?im)^\s*GO\s*(?:--.*)?$')
    Write-Log "Running $RelativePath ($($batches.Count) batches)"

    # A fresh connection per script isolates session-scoped #temp objects. A
    # test suite creates #Results in one batch and uses it in later batches, so
    # the batches within a script must share this connection.
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.add_InfoMessage($infoHandler)
    $connection.Open()
    $index = 0
    try {
        foreach ($batch in $batches) {
            $index++
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }

            $command = $connection.CreateCommand()
            $command.CommandTimeout = 300
            $command.CommandText = $batch
            try {
                $reader = $command.ExecuteReader()
                do {
                    if ($reader.FieldCount -gt 0) {
                        $headers = @()
                        for ($i = 0; $i -lt $reader.FieldCount; $i++) { $headers += $reader.GetName($i) }
                        Write-Host ("  " + ($headers -join ' | '))
                        while ($reader.Read()) {
                            $values = @()
                            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                $values += [string]$reader.GetValue($i)
                            }
                            Write-Host ("  " + ($values -join ' | '))
                        }
                    }
                } while ($reader.NextResult())
                $reader.Close()
            }
            catch {
                Write-Log "FAILED in $RelativePath batch $index`: $($_.Exception.Message)"
                throw
            }
            finally {
                $command.Dispose()
            }
        }
    }
    finally {
        if ($connection.State -eq 'Open') { $connection.Close() }
        $connection.Dispose()
    }
}

try {
    Write-Log "Server: $Server"
    $versionConnection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $versionConnection.Open()
    $versionCommand = $versionConnection.CreateCommand()
    $versionCommand.CommandText = "SET NOCOUNT ON; SELECT @@VERSION AS Version, CAST(SERVERPROPERTY('Edition') AS varchar(128)) AS Edition;"
    $versionReader = $versionCommand.ExecuteReader()
    while ($versionReader.Read()) {
        Write-Log ("Version: " + $versionReader.GetValue(0))
        Write-Log ("Edition: " + $versionReader.GetValue(1))
    }
    $versionReader.Close()
    $versionCommand.Dispose()
    $versionConnection.Close()
    $versionConnection.Dispose()

    $scripts = @(
        'sql-server/databases/01_create_databases.sql',
        'sql-server/schemas/02_create_schemas.sql',
        'sql-server/tables/03_create_tables_core.sql',
        'sql-server/tables/03_create_tables_payments.sql',
        'sql-server/tables/03_create_tables_customer_service.sql',
        'sql-server/tables/03_create_tables_audit.sql',
        'sql-server/tables/03_create_tables_reporting.sql',
        'sql-server/tables/03_create_tables_fraud.sql',
        'sql-server/tables/04_seed_reference.sql',
        'sql-server/indexes/04_create_indexes.sql',
        'sql-server/views/06_create_views.sql',
        'sql-server/functions/07_create_functions.sql',
        'sql-server/procedures/05_transfer_engine.sql',
        'sql-server/procedures/05_payment_procedures.sql'
    )

    foreach ($script in $scripts) { Invoke-SqlFile -RelativePath $script }
    Invoke-SqlFile -RelativePath 'sql-server/security/09_create_users_roles.sql' -LocalDbSecurity

    if (-not $SkipTests) {
        foreach ($test in @(
            'sql-server/tests/01_schema_tests.sql',
            'sql-server/tests/02_transfer_tests.sql',
            'sql-server/tests/03_security_tests.sql',
            'sql-server/tests/04_payment_tests.sql'
        )) {
            Invoke-SqlFile -RelativePath $test
        }
    }

    if ($Exercises) {
        $databases = @('AFS_CoreBanking', 'AFS_Payments', 'AFS_CustomerService', 'AFS_Audit', 'AFS_Reporting', 'AFS_Fraud')
        foreach ($database in $databases) {
            New-Item -ItemType Directory -Path (Join-Path $BackupRoot $database) -Force | Out-Null
            $variables.DatabaseName = $database
            Invoke-SqlFile -RelativePath 'sql-server/backup/20_backup_full.sql' -LocalDbBackup
        }

        $variables.DatabaseName = 'AFS_CoreBanking'
        Invoke-SqlFile -RelativePath 'sql-server/backup/21_backup_differential.sql' -LocalDbBackup
        Invoke-SqlFile -RelativePath 'sql-server/backup/22_backup_log.sql' -LocalDbBackup

        $fullBackup = Get-ChildItem -LiteralPath (Join-Path $BackupRoot 'AFS_CoreBanking') -Filter '*_FULL_*.bak' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $logBackup = Get-ChildItem -LiteralPath (Join-Path $BackupRoot 'AFS_CoreBanking') -Filter '*_LOG_*.trn' |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $fullBackup -or -not $logBackup) {
            throw 'Backup exercise did not produce the expected full and log files.'
        }

        $variables.BackupFile = $fullBackup.FullName
        Invoke-SqlFile -RelativePath 'sql-server/backup/23_backup_verify.sql'
        Invoke-SqlFile -RelativePath 'sql-server/backup/24_backup_history.sql'

        Invoke-SqlFile -RelativePath 'sql-server/recovery/30_restore_full_core.sql'
        $variables.BackupFile = $logBackup.FullName
        $variables.StopAt = ''
        $variables.IsLog = '1'
        Invoke-SqlFile -RelativePath 'sql-server/recovery/31_restore_log.sql'
        Invoke-SqlFile -RelativePath 'sql-server/recovery/32_restore_verify.sql'
        Invoke-SqlFile -RelativePath 'sql-server/recovery/33_restore_history.sql'

        # These are the same measurement harnesses, run on the current smoke-scale
        # data. They prove the harness executes; they are not a performance claim.
        Invoke-SqlFile -RelativePath 'sql-server/performance/60_baseline.sql'
        Invoke-SqlFile -RelativePath 'sql-server/performance/61_case1_before.sql'
        Invoke-SqlFile -RelativePath 'sql-server/performance/62_case1_optimize.sql' -DisableOnlineIndex
        Invoke-SqlFile -RelativePath 'sql-server/performance/63_case1_after.sql'
        Invoke-SqlFile -RelativePath 'sql-server/performance/64_case2_before.sql'
        Invoke-SqlFile -RelativePath 'sql-server/performance/65_case2_after.sql'
    }

    Write-Log 'Completed. Review the result sets and log; a zero exit code alone is not proof that every assertion passed.'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}

Write-Host "Log: $logFile"
