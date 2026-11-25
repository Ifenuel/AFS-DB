# Watchdog for the payments database.
#
# Two jobs in one process, so there is no race between them:
#   1. ship the transaction log to the standby every second while the primary is
#      healthy, which bounds how much committed work can be lost;
#   2. when the primary stops answering, promote the standby and republish the
#      endpoint the application reads.
# This is failover without an availability group: the witness is this process and
# the endpoint is a file. Both are named in the evidence.
param(
    [string]$Primary   = '.',
    [string]$Standby   = '(localdb)\MSSQLLocalDB',
    [string]$Database  = 'AFS_Payments',
    [string]$StandbyDb = 'AFS_Payments_Standby',
    [string]$Endpoint  = 'ha\active_target.json',
    [string]$Log       = 'C:\Backups\ha\watchdog.log',
    [string]$ShipDir   = 'C:\Backups\ha',
    [int]$ShipIntervalMs = 1000,
    [int]$IntervalMs   = 250,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$started = Get-Date

function Write-Log([string]$m) {
    $line = '{0:HH:mm:ss.fff}  {1}' -f (Get-Date), $m
    Add-Content -Path $Log -Value $line -Encoding utf8
    Write-Host $line
}

function New-Connection([string]$server, [string]$db) {
    $cs = "Server=$server;Database=$db;Integrated Security=True;Encrypt=False;Connect Timeout=2;Application Name=AFS-HA-Watchdog"
    return New-Object System.Data.SqlClient.SqlConnection($cs)
}

function Exec([string]$server, [string]$db, [string]$sql) {
    $c = New-Connection $server $db
    try {
        $c.Open()
        $cmd = $c.CreateCommand()
        $cmd.CommandTimeout = 60
        $cmd.CommandText = $sql
        $cmd.ExecuteNonQuery() | Out-Null
    } finally { $c.Dispose() }
}

function Get-Status([string]$server, [string]$db) {
    $c = New-Connection $server 'master'
    try {
        $c.Open()
        $cmd = $c.CreateCommand()
        $cmd.CommandText = "SELECT CAST(DATABASEPROPERTYEX(@db, 'Status') AS varchar(40))"
        $cmd.Parameters.AddWithValue('@db', $db) | Out-Null
        return [string]$cmd.ExecuteScalar()
    } finally { $c.Dispose() }
}

function Count-Rows {
    $c = New-Connection $Standby $StandbyDb
    try {
        $c.Open()
        $cmd = $c.CreateCommand()
        $cmd.CommandText = 'SELECT COUNT_BIG(*) FROM payment.Payment'
        return [long]$cmd.ExecuteScalar()
    } finally { $c.Dispose() }
}

Set-Content -Path $Log -Value '' -Encoding utf8
if (-not (Test-Path $ShipDir)) { New-Item -ItemType Directory -Path $ShipDir | Out-Null }
$shipFile = Join-Path $ShipDir 'watchdog_ship.trn'

Write-Log "watchdog start   primary=$Primary  standby=$Standby"
Write-Log "monitoring       $Database every $IntervalMs ms; log shipped every $ShipIntervalMs ms"
Write-Log 'state            HEALTHY'

$deadline = $started.AddSeconds($TimeoutSeconds)
$failures = 0
$outageStart = $null
$ships = 0
$lastShip = (Get-Date).AddMinutes(-1)
$lastShipMs = 0
$lastShipAt = $null

while ((Get-Date) -lt $deadline) {
    $status = $null
    $errorText = $null
    try { $status = Get-Status $Primary $Database }
    catch { $errorText = $_.Exception.Message.Split("`n")[0].Trim() }

    if ($status -eq 'ONLINE') {
        if ($failures -gt 0) { Write-Log "state            HEALTHY again after $failures failed probe(s)" }
        $failures = 0

        if (((Get-Date) - $lastShip).TotalMilliseconds -ge $ShipIntervalMs) {
            try {
                $t0 = Get-Date
                Exec $Primary 'master' "BACKUP LOG [$Database] TO DISK = N'$shipFile' WITH INIT, CHECKSUM"
                Exec $Standby 'master' "RESTORE LOG [$StandbyDb] FROM DISK = N'$shipFile' WITH NORECOVERY"
                $ships++
                $lastShipMs = [int]((Get-Date) - $t0).TotalMilliseconds
                $lastShipAt = Get-Date
                if ($ships -eq 1 -or $ships % 10 -eq 0) {
                    Write-Log "log shipped      #$ships in $lastShipMs ms"
                }
            } catch {
                Write-Log ("ship warning     " + $_.Exception.Message.Split("`n")[0].Trim())
            }
            $lastShip = Get-Date
        }
        Start-Sleep -Milliseconds $IntervalMs
        continue
    }

    if ($failures -eq 0) { $outageStart = Get-Date }
    $failures++
    $why = if ($errorText) { $errorText } else { "status=$status" }
    if ($failures -eq 1) { Write-Log "primary lost     $why" }

    # Two consecutive failures before acting: one missed heartbeat is a dropped
    # packet, not a dead database.
    if ($failures -ge 2) {
        $t0 = Get-Date
        Exec $Standby 'master' "RESTORE DATABASE [$StandbyDb] WITH RECOVERY"
        $promoteMs = [int]((Get-Date) - $t0).TotalMilliseconds
        $rows = Count-Rows

        $endpointDir = Split-Path -Parent $Endpoint
        if ($endpointDir -and -not (Test-Path $endpointDir)) { New-Item -ItemType Directory -Path $endpointDir | Out-Null }
        [ordered]@{
            server          = $Standby
            database        = $StandbyDb
            role            = 'primary'
            promoted_at     = (Get-Date).ToString('s')
            promote_ms      = $promoteMs
            detected_ms     = [int]((Get-Date) - $outageStart).TotalMilliseconds
            standby_rows    = $rows
            logs_shipped    = $ships
            last_ship_at    = if ($lastShipAt) { $lastShipAt.ToString('HH:mm:ss.fff') } else { 'none' }
            last_ship_ms    = $lastShipMs
        } | ConvertTo-Json | ForEach-Object { [IO.File]::WriteAllText($Endpoint, $_) }

        Write-Log "PROMOTED         $StandbyDb on $Standby in $promoteMs ms"
        Write-Log "logs shipped     $ships (last at $(if ($lastShipAt) { $lastShipAt.ToString('HH:mm:ss.fff') } else { 'none' }))"
        Write-Log "endpoint         $Endpoint -> $Standby / $StandbyDb"
        Write-Log "standby rows     $rows (payment.Payment)"
        Write-Log 'state            FAILED OVER'
        exit 0
    }
    Start-Sleep -Milliseconds $IntervalMs
}

Write-Log 'state            TIMEOUT without failover'
exit 1
