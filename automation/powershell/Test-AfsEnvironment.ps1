#requires -Version 5.1
<#
.SYNOPSIS
    Read-only readiness check for the AFS DBA lab.

.DESCRIPTION
    Reports OS, CPU, memory, disk, privilege, client and service status. It does
    not install or change anything. Exit codes: 0 = no failures, 1 = warnings,
    2 = failures (for example, no sqlcmd when SQL Server work is required).
#>
[CmdletBinding()]
param(
    [string]$Server = $(if ($env:AFS_SQL_SERVER) { $env:AFS_SQL_SERVER } else { 'localhost' })
)

$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Area,
        [string]$Check,
        [string]$Status,
        [string]$Details
    )
    $results.Add([pscustomobject]@{
        Area = $Area; Check = $Check; Status = $Status; Details = $Details
    })
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $volume = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue

    Add-Result 'OS' 'Operating system' 'PASS' "$($os.Caption) $($os.Version) $($os.OSArchitecture)"
    Add-Result 'CPU' 'Processor' 'PASS' "$($cpu.Name); $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
    $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    Add-Result 'Memory' 'Physical memory' $(if ($ramGb -ge 8) { 'PASS' } else { 'WARN' }) "$ramGb GB visible"
    if ($volume) {
        $freeGb = [math]::Round($volume.SizeRemaining / 1GB, 2)
        Add-Result 'Storage' 'C: free space' $(if ($freeGb -ge 30) { 'PASS' } elseif ($freeGb -ge 20) { 'WARN' } else { 'FAIL' }) "$freeGb GB free"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Result 'Privilege' 'Elevated administrator token' $(if ($isAdmin) { 'PASS' } else { 'WARN' }) "Identity $($identity.Name); elevated=$isAdmin"

    foreach ($commandName in @('git', 'python', 'code')) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        Add-Result 'Client' $commandName $(if ($cmd) { 'PASS' } else { 'FAIL' }) $(if ($cmd) { $cmd.Source } else { 'not found on PATH' })
    }

    $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $sqlcmd -and (Test-Path -LiteralPath 'C:\Program Files\SqlCmd\sqlcmd.exe')) {
        $sqlcmd = Get-Item -LiteralPath 'C:\Program Files\SqlCmd\sqlcmd.exe'
    }
    Add-Result 'Client' 'sqlcmd' $(if ($sqlcmd) { 'PASS' } else { 'FAIL' }) $(if ($sqlcmd) { $sqlcmd.Source } else { 'not found; install Microsoft.Sqlcmd' })

    $isLocalDb = $Server -match '^\(localdb\)'
    if ($isLocalDb) {
        $localDbExe = 'C:\Program Files\Microsoft SQL Server\170\Tools\Binn\SqlLocalDB.exe'
        if (Test-Path -LiteralPath $localDbExe) {
            $localDbInfo = & $localDbExe info 2>&1
            Add-Result 'Service' 'LocalDB instance' 'INFO' (($localDbInfo | Out-String).Trim())
        }
        else {
            Add-Result 'Service' 'LocalDB instance' 'WARN' 'SqlLocalDB.exe not found'
        }
    }

    $services = Get-Service | Where-Object { $_.Name -match 'MSSQL|MySQL|Oracle|postgres' }
    if ($services) {
        foreach ($service in $services) {
            Add-Result 'Service' $service.Name 'INFO' "$($service.Status) / $($service.StartType)"
        }
    }
    else {
        Add-Result 'Service' 'Database services' 'WARN' 'No SQL Server/MySQL/Oracle/PostgreSQL service found'
    }

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object LocalPort -in 1433, 3306, 1521, 5432
    if ($listeners) {
        foreach ($listener in $listeners) {
            Add-Result 'Port' "Port $($listener.LocalPort)" 'INFO' "Listening on $($listener.LocalAddress)"
        }
    }

    if ($isLocalDb) {
        try {
            $connectionString = "Server=$Server;Integrated Security=true;Connect Timeout=30;Encrypt=false"
            $sqlConnection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
            $sqlConnection.Open()
            $command = $sqlConnection.CreateCommand()
            $command.CommandText = "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS varchar(128)) + '|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(64));"
            $edition = [string]$command.ExecuteScalar()
            $sqlConnection.Close()
            Add-Result 'SQL' 'SQL Server connection' 'PASS' $edition
        }
        catch {
            Add-Result 'SQL' 'SQL Server connection' 'FAIL' $_.Exception.Message
        }
    }
    elseif ($sqlcmd) {
        $query = "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS varchar(128)) + '|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(64));"
        $connection = & sqlcmd -S $Server -E -b -I -h -1 -W -Q $query 2>&1
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'SQL' 'SQL Server connection' 'PASS' ($connection -join ' ').Trim()
        }
        else {
            Add-Result 'SQL' 'SQL Server connection' 'FAIL' (($connection -join ' ').Trim())
        }
    }
}
catch {
    Add-Result 'Script' 'Environment check' 'FAIL' $_.Exception.Message
}

$results | Format-Table -AutoSize
$failures = @($results | Where-Object Status -eq 'FAIL').Count
$warnings = @($results | Where-Object Status -eq 'WARN').Count
Write-Host "Failures: $failures; warnings: $warnings"
if ($failures -gt 0) { exit 2 }
if ($warnings -gt 0) { exit 1 }
exit 0
