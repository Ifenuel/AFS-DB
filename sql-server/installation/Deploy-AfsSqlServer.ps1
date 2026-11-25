#requires -Version 5.1
<#
.SYNOPSIS
    Deploy the AFS SQL Server lab from an empty instance.

.DESCRIPTION
    Runs the versioned SQL scripts in dependency order using sqlcmd. It does not
    install SQL Server. Passwords are read from process environment variables and
    passed to sqlcmd as scripting variables; they are never written to this repo.
    Command-line arguments can be visible to other local processes briefly, so use
    disposable lab passwords and a trusted machine.

.PARAMETER Server
    SQL Server instance. Default: localhost.

.PARAMETER SqlCmdPath
    Path to sqlcmd.exe. Default: resolved from PATH.

.PARAMETER SkipTests
    Skip the post-deployment test scripts.

.EXAMPLE
    $env:AFS_APP_PASSWORD = '<lab password>'
    .\Deploy-AfsSqlServer.ps1 -Server localhost
#>
[CmdletBinding()]
param(
    [string]$Server = $(if ($env:AFS_SQL_SERVER) { $env:AFS_SQL_SERVER } else { 'localhost' }),
    [string]$DataRoot = $(if ($env:AFS_DATA_ROOT) { $env:AFS_DATA_ROOT } else { 'C:\AFS\Data' }),
    [string]$LogRoot = $(if ($env:AFS_LOG_ROOT) { $env:AFS_LOG_ROOT } else { 'C:\AFS\Log' }),
    [string]$BackupRoot = $(if ($env:AFS_BACKUP_ROOT) { $env:AFS_BACKUP_ROOT } else { 'C:\AFS\Backups' }),
    [string]$AuditRoot = $(if ($env:AFS_AUDIT_ROOT) { $env:AFS_AUDIT_ROOT } else { 'C:\AFS\Audit' }),
    [string]$SqlCmdPath,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path $repoRoot 'logs'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logFile = Join-Path $logDir "deploy-$stamp.log"

function Write-Step {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('s'), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Assert-Password {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -lt 16) {
        throw "Environment variable $Name must be set to a lab password of at least 16 characters."
    }
}

function Invoke-SqlFile {
    param(
        [string]$RelativePath,
        [string[]]$Variables = @()
    )

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "SQL script not found: $path"
    }

    Write-Step "Running $RelativePath"
    $arguments = @('-S', $Server, '-E', '-b', '-I', '-l', '60', '-i', $path)
    if ($Variables.Count -gt 0) {
        $arguments += '-v'
        $arguments += $Variables
    }

    # Do not echo $arguments: they can contain passwords.
    & $SqlCmdPath @arguments 2>&1 | Tee-Object -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed for $RelativePath with exit code $LASTEXITCODE. See $logFile."
    }
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Step "Identity: $($identity.Name); elevated administrator: $isAdmin"
if (-not $isAdmin) {
    Write-Warning 'This session is not elevated. Deployment may succeed with Windows Authentication, but directory creation and SQL Server file access may fail.'
}

if (-not $SqlCmdPath) {
    $command = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'sqlcmd was not found. Install Microsoft.Sqlcmd or SSMS, then re-run this script.'
    }
    $SqlCmdPath = $command.Source
}
Write-Step "Using sqlcmd: $SqlCmdPath"

$requiredPasswords = @(
    'AFS_DBA_PASSWORD',
    'AFS_APP_PASSWORD',
    'AFS_DEVELOPER_PASSWORD',
    'AFS_REPORTING_PASSWORD',
    'AFS_AUDITOR_PASSWORD',
    'AFS_OPS_PASSWORD'
)
foreach ($name in $requiredPasswords) { Assert-Password -Name $name }

foreach ($directory in @($DataRoot, $LogRoot, $BackupRoot, $AuditRoot)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Step "Created directory $directory"
    }
}

# Connectivity and version preflight.
Write-Step 'Checking SQL Server connectivity and edition'
$preflight = & $SqlCmdPath -S $Server -E -b -I -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS varchar(128)) + '|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(64));" 2>&1
$preflight | Tee-Object -FilePath $logFile -Append
if ($LASTEXITCODE -ne 0) {
    throw "Cannot connect to SQL Server '$Server' with Windows Authentication. See $logFile."
}

$commonVariables = @(
    "DataRoot=$DataRoot",
    "LogRoot=$LogRoot",
    "BackupRoot=$BackupRoot",
    "AuditRoot=$AuditRoot"
)

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
    'sql-server/procedures/05_payment_procedures.sql',
    'sql-server/security/08_create_logins.sql',
    'sql-server/security/09_create_users_roles.sql',
    'sql-server/security/10_configure_audit.sql'
)

foreach ($script in $scripts) {
    if ($script -eq 'sql-server/security/08_create_logins.sql') {
        $variables = $commonVariables + @(
            "AFS_DBA_PASSWORD=$env:AFS_DBA_PASSWORD",
            "AFS_APP_PASSWORD=$env:AFS_APP_PASSWORD",
            "AFS_DEVELOPER_PASSWORD=$env:AFS_DEVELOPER_PASSWORD",
            "AFS_REPORTING_PASSWORD=$env:AFS_REPORTING_PASSWORD",
            "AFS_AUDITOR_PASSWORD=$env:AFS_AUDITOR_PASSWORD",
            "AFS_OPS_PASSWORD=$env:AFS_OPS_PASSWORD"
        )
        Invoke-SqlFile -RelativePath $script -Variables $variables
    }
    else {
        Invoke-SqlFile -RelativePath $script -Variables $commonVariables
    }
}

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

Write-Step 'Deployment completed. Review the log and the test output; a script exit code alone is not proof of correctness.'
Write-Host "Log: $logFile"
