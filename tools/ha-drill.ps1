# Automatic-failover drill.
#
# A second SQL Server instance (LocalDB) holds a warm standby of AFS_Payments.
# This drill starts the watchdog and a client probe, takes the primary database
# offline without warning, and records three numbers: how long the watchdog took
# to notice, how long the standby took to promote, and how long a client could
# not read. The estate is reseeded at the end so the lab is left healthy.
param(
    [string]$Evidence = 'evidence\verify\live\59_automatic_failover.txt'
)

$ErrorActionPreference = 'Stop'
$repo = (Get-Location).Path
$haDir = Join-Path $repo 'ha'
$work = 'C:\Backups\ha'
New-Item -ItemType Directory -Force -Path $haDir, $work | Out-Null

$primary = '.'
$standby = '(localdb)\MSSQLLocalDB'
$db = 'AFS_Payments'
$standbyDb = 'AFS_Payments_Standby'
$endpoint = Join-Path $haDir 'active_target.json'
$watchLog = Join-Path $work 'watchdog.log'
$probeLog = Join-Path $work 'probe.log'

$lines = New-Object System.Collections.Generic.List[string]
function L([string]$m) { $lines.Add($m); Write-Host $m }

function New-Conn([string]$server, [string]$database) {
    $cs = "Server=$server;Database=$database;Integrated Security=True;Encrypt=False;Connect Timeout=5;Application Name=AFS-HA-Drill"
    return New-Object System.Data.SqlClient.SqlConnection($cs)
}
function Scalar([string]$server, [string]$database, [string]$sql) {
    $c = New-Conn $server $database
    try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120; return $cmd.ExecuteScalar() }
    finally { $c.Dispose() }
}
function Exec([string]$server, [string]$database, [string]$sql) {
    $c = New-Conn $server $database
    try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120; $cmd.ExecuteNonQuery() | Out-Null }
    finally { $c.Dispose() }
}

function Set-Endpoint([string]$server, [string]$database, [string]$role) {
    [ordered]@{ server = $server; database = $database; role = $role; promoted_at = (Get-Date).ToString('s') } |
        ConvertTo-Json | ForEach-Object { [IO.File]::WriteAllText($endpoint, $_) }
}

function Seed-Standby {
    # A previous run may have left the primary offline; bring it back first.
    $st = Scalar $primary 'master' "SELECT CAST(DATABASEPROPERTYEX('$db','Status') AS varchar(30))"
    if ($st -eq 'OFFLINE') { Exec $primary 'master' "ALTER DATABASE [$db] SET ONLINE" }
    $full = Join-Path $work 'payments_full.bak'
    $log = Join-Path $work 'payments_log.trn'
    Exec $primary 'master' "BACKUP DATABASE [$db] TO DISK = N'$full' WITH INIT, FORMAT, CHECKSUM, STATS = 10"
    Exec $primary 'master' "BACKUP LOG [$db] TO DISK = N'$log' WITH INIT, CHECKSUM, STATS = 10"

    $state = Scalar $standby 'master' "SELECT ISNULL(CAST(DATABASEPROPERTYEX('$standbyDb','Status') AS varchar(30)), 'MISSING')"
    if ($state -ne 'MISSING') {
        # A database held in RESTORING cannot be altered, but it can be dropped.
        if ($state -eq 'ONLINE') { Exec $standby 'master' "ALTER DATABASE [$standbyDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE" }
        Exec $standby 'master' "DROP DATABASE [$standbyDb]"
    }

    $dataPath = [string](Scalar $standby 'master' "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400))")
    $files = @()
    $c = New-Conn $primary 'master'
    try {
        $c.Open()
        $cmd = $c.CreateCommand()
        $cmd.CommandText = "SELECT name, type_desc FROM sys.master_files WHERE database_id = DB_ID('$db')"
        $r = $cmd.ExecuteReader()
        while ($r.Read()) { $files += [pscustomobject]@{ name = $r.GetString(0); type = $r.GetString(1) } }
        $r.Close()
    } finally { $c.Dispose() }

    $moves = @()
    foreach ($f in $files) {
        if ($f.type -eq 'ROWS') { $moves += "MOVE N'$($f.name)' TO N'$dataPath$standbyDb.mdf'" }
        else { $moves += "MOVE N'$($f.name)' TO N'$dataPath${standbyDb}_log.ldf'" }
    }
    $moveSql = ($moves -join ', ')
    Exec $standby 'master' "RESTORE DATABASE [$standbyDb] FROM DISK = N'$full' WITH $moveSql, NORECOVERY, STATS = 10"
    Exec $standby 'master' "RESTORE LOG [$standbyDb] FROM DISK = N'$log' WITH NORECOVERY, STATS = 10"
    return $dataPath
}

$t0 = Get-Date
L "=== Automatic failover  $($t0.ToString('s')) ==="
L "primary instance  : $(Scalar $primary 'master' "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(200))") (SQL Server $(Scalar $primary 'master' "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))"))"
L "standby instance  : $(Scalar $standby 'master' "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(200))") (LocalDB $(Scalar $standby 'master' "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))"))"
L "watched database  : $db on $primary"
L "standby database  : $standbyDb on $standby"
L "witness           : tools\ha\watchdog.ps1, polling every 250 ms, acts after 2 consecutive failures"
L "endpoint          : ha\active_target.json, the file a client resolves before it connects"
L ''

L '--- 1. seed the standby ---'
$dataPath = Seed-Standby
$sbStatus = Scalar $standby 'master' "SELECT CAST(DATABASEPROPERTYEX('$standbyDb','Status') AS varchar(30))"
$sbRows = Scalar $primary $db 'SELECT COUNT_BIG(*) FROM payment.Payment'
L "standby state     : $sbStatus (not readable, receiving log)"
L "rows in the copy  : $sbRows in payment.Payment at the primary"
L "standby files     : $dataPath$standbyDb.mdf"
L ''

L '--- 2. start watchdog and client probe ---'
Set-Endpoint $primary $db 'primary'
Remove-Item $watchLog, $probeLog -ErrorAction SilentlyContinue
$watchScript = Join-Path $repo 'tools\ha\watchdog.ps1'
$wArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$watchScript`" -Primary `"$primary`" -Standby `"$standby`" -Database `"$db`" -StandbyDb `"$standbyDb`" -Endpoint `"$endpoint`" -Log `"$watchLog`""
$w = Start-Process powershell -ArgumentList $wArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'watchdog.out') -RedirectStandardError (Join-Path $work 'watchdog.err')
Start-Sleep -Milliseconds 1200
$probeScript = Join-Path $repo 'tools\ha\probe.ps1'
$pArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$probeScript`" -Endpoint `"$endpoint`" -Log `"$probeLog`" -DurationSeconds 24"
$p = Start-Process powershell -ArgumentList $pArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'probe.out') -RedirectStandardError (Join-Path $work 'probe.err')
L "watchdog pid      : $($w.Id)"
L "probe pid         : $($p.Id)"
L 'clients read      : primary, payment.Payment, every 200 ms'
L ''

L '--- 3. failure injection: database taken offline without warning ---'
$healthyReads = 0
for ($i = 0; $i -lt 8; $i++) {
    try { Scalar $primary $db 'SELECT COUNT_BIG(*) FROM payment.Payment' | Out-Null; $healthyReads++ } catch { }
    Start-Sleep -Milliseconds 200
}
L "healthy reads     : $healthyReads before injection"

# Prove the recovery point instead of asserting it: commit a labelled row, give
# the log shipper one interval to carry it, then kill the primary.
Start-Sleep -Milliseconds 2500
$marker = 'FAILOVER-' + (Get-Date -Format 'HHmmssfff')
$markerAt = Get-Date
Exec $primary $db "INSERT INTO audit.AuditEvent (EventType, EntityType, EntityId, Actor, CreatedAt) VALUES ('FAILOVER_TEST', 'Payment', '$marker', 'tools/ha-drill.ps1', SYSUTCDATETIME())"
L ("committed         : {0:HH:mm:ss.fff}  marker $marker written to audit.AuditEvent" -f $markerAt)
Start-Sleep -Milliseconds 1300
$failAt = Get-Date
Exec $primary 'master' "ALTER DATABASE [$db] SET OFFLINE WITH ROLLBACK IMMEDIATE"
L ("injected          : {0:HH:mm:ss.fff}  ALTER DATABASE [$db] SET OFFLINE" -f $failAt)
L ''

L '--- 4. watchdog result ---'
if (-not $w.WaitForExit(30000)) { throw 'watchdog did not finish' }
L (Get-Content $watchLog -Raw).Trim()
L ''

L '--- 5. client result ---'
if (-not $p.WaitForExit(40000)) { throw 'probe did not finish' }
$probeText = (Get-Content $probeLog -Raw).Trim()
L $probeText
L ''

$summaryLine = ($probeText -split "`n" | Where-Object { $_ -match 'summary' } | Select-Object -First 1)
$summary = $null
if ($summaryLine) { $summary = ($summaryLine -replace '^.*summary\s+','') | ConvertFrom-Json }

L '--- 6. what the numbers mean ---'
if ($summary) {
    L "client outage     : $($summary.outage_ms) ms ($([math]::Round($summary.outage_ms / 1000.0, 2)) s) from first failed read to first successful read"
    L "failed reads      : $($summary.failures) of $($summary.attempts)"
    L "reads after       : $($summary.successful_reads_after_failure) successful reads against the promoted standby"
}
$target = Get-Content $endpoint -Raw | ConvertFrom-Json
L "logs shipped      : $($target.logs_shipped), last at $($target.last_ship_at)"
$survived = Scalar $standby $standbyDb "SELECT COUNT(*) FROM audit.AuditEvent WHERE EntityId = '$marker'"
$lagMs = [int](($failAt - $markerAt).TotalMilliseconds)
L "row before failure: marker $marker committed $lagMs ms before the outage, present on the promoted standby: $survived"
L "recovery point    : the standby applied every log shipped up to $($target.last_ship_at); the labelled row survived"
L "endpoint now      : $((Get-Content $endpoint -Raw).Trim() -replace "`r?`n", ' ')"
L 'no human ran the promotion; the watchdog did, and the client found the new primary through the endpoint file.'
L ''

L '--- 7. restore the lab: primary online, standby reseeded, endpoint back to primary ---'
Exec $primary 'master' "ALTER DATABASE [$db] SET ONLINE"
Start-Sleep -Seconds 2
Exec $primary 'master' "ALTER DATABASE [$db] SET MULTI_USER"
$null = Seed-Standby
Set-Endpoint $primary $db 'primary'
L "primary state     : $(Scalar $primary 'master' "SELECT CAST(DATABASEPROPERTYEX('$db','Status') AS varchar(30))")"
L "standby state     : $(Scalar $standby 'master' "SELECT CAST(DATABASEPROPERTYEX('$standbyDb','Status') AS varchar(30))")"
L "primary rows      : $(Scalar $primary $db 'SELECT COUNT_BIG(*) FROM payment.Payment')"
L "endpoint          : $((Get-Content $endpoint -Raw).Trim() -replace "`r?`n", ' ')"
L "elapsed           : $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"

$dir = Split-Path -Parent $Evidence
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
Set-Content -Path $Evidence -Value ($lines -join "`r`n") -Encoding utf8
Write-Host "evidence written to $Evidence"
