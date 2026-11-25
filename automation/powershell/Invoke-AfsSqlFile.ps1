#requires -Version 5.1
<#
.SYNOPSIS
    Run one self-contained SQL file against the AFS LocalDB instance.
.DESCRIPTION
    Uses ADO.NET because the installed go-sqlcmd build cannot resolve
    (localdb)\MSSQLLocalDB on this host. Splits on GO and keeps one connection
    so session-scoped temp tables survive across batches.

    This runner does not substitute $(Variable) placeholders. Use
    Invoke-AfsLocalDb.ps1 for deployment, backup and restore scripts that need
    variables.
.EXAMPLE
    .\Invoke-AfsSqlFile.ps1 -File sql-server/tests/03_security_tests.sql
.EXAMPLE
    .\Invoke-AfsSqlFile.ps1 -Database AFS_CoreBanking -Query "SELECT TOP 5 * FROM account.Account;"
#>
[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$File,
    [Parameter(Mandatory, ParameterSetName = 'Query')]
    [string]$Query,
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [string]$Database = 'master'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$connectionString = "Server=$Server;Database=$Database;Integrated Security=true;Connect Timeout=30;Encrypt=false;Application Name=AFS-SqlFile-Runner"
$connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)

function Invoke-Batch {
    param([string]$Sql)
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 300
    $command.CommandText = $Sql
    $reader = $command.ExecuteReader()
    do {
        if ($reader.FieldCount -gt 0) {
            $headers = @()
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $headers += $reader.GetName($i) }
            Write-Host ($headers -join ' | ')
            Write-Host (($headers | ForEach-Object { '-' * $_.Length }) -join '-+-')
            while ($reader.Read()) {
                $values = @()
                for ($i = 0; $i -lt $reader.FieldCount; $i++) { $values += [string]$reader.GetValue($i) }
                Write-Host ($values -join ' | ')
            }
        }
    } while ($reader.NextResult())
    $reader.Close()
    $command.Dispose()
}

try {
    $connection.Open()
    if ($PSCmdlet.ParameterSetName -eq 'Query') {
        Invoke-Batch -Sql $Query
    }
    else {
        $path = if (Test-Path -LiteralPath $File) { (Resolve-Path -LiteralPath $File).Path }
                else { Join-Path $repoRoot $File }
        if (-not (Test-Path -LiteralPath $path)) { throw "SQL file not found: $File" }
        $content = Get-Content -LiteralPath $path -Raw
        $batches = [regex]::Split($content, '(?im)^\s*GO\s*(?:--.*)?$')
        Write-Host "Running $path ($($batches.Count) batch(es))"
        foreach ($batch in $batches) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            Invoke-Batch -Sql $batch
        }
    }
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($connection.State -eq 'Open') { $connection.Close() }
    $connection.Dispose()
}
