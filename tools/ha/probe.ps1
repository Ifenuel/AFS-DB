# Client probe for the failover drill.
#
# Reads the endpoint file the same way an application would, then asks the
# database for a row count every few hundred milliseconds. It records the exact
# window in which the application could not read, which is the number that
# matters - not the time the watchdog spent promoting.
param(
    [string]$Endpoint = 'ha\active_target.json',
    [string]$Log = 'C:\Backups\ha\probe.log',
    [int]$DurationSeconds = 30,
    [int]$IntervalMs = 200
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$m) {
    $line = '{0:HH:mm:ss.fff}  {1}' -f (Get-Date), $m
    Add-Content -Path $Log -Value $line -Encoding utf8
}

Set-Content -Path $Log -Value '' -Encoding utf8
Write-Log 'probe start'

$deadline = (Get-Date).AddSeconds($DurationSeconds)
$attempts = 0
$failures = 0
$firstFail = $null
$lastFail = $null
$recovered = $null
$okAfterFail = 0
$lastState = 'ok'

while ((Get-Date) -lt $deadline) {
    $attempts++
    $server = $null; $database = $null
    try {
        $target = Get-Content -Path $Endpoint -Raw -ErrorAction Stop | ConvertFrom-Json
        $server = $target.server
        $database = $target.database
    } catch {
        $server = '.'; $database = 'AFS_Payments'
    }

    $ok = $false
    $detail = $null
    try {
        $cs = "Server=$server;Database=$database;Integrated Security=True;Encrypt=False;Connect Timeout=1;Application Name=AFS-HA-Probe"
        $c = New-Object System.Data.SqlClient.SqlConnection($cs)
        try {
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText = 'SELECT COUNT_BIG(*) FROM payment.Payment'
            $rows = [long]$cmd.ExecuteScalar()
            $ok = $true
        } finally { $c.Dispose() }
    } catch {
        $detail = $_.Exception.Message.Split("`n")[0].Trim()
    }

    if (-not $ok) {
        $failures++
        if (-not $firstFail) { $firstFail = Get-Date; Write-Log "read failed    $server/$database : $detail" }
        $lastFail = Get-Date
        $lastState = 'failed'
    } else {
        if ($lastState -eq 'failed' -and -not $recovered) {
            $recovered = Get-Date
            $outage = ($recovered - $firstFail).TotalMilliseconds
            Write-Log ("read recovered {0}/{1} : {2} rows after {3:N0} ms" -f $server, $database, $rows, $outage)
        }
        if ($firstFail -and $recovered) { $okAfterFail++ }
        $lastState = 'ok'
    }
    Start-Sleep -Milliseconds $IntervalMs
}

$summary = [ordered]@{
    attempts        = $attempts
    failures        = $failures
    first_failure   = if ($firstFail) { $firstFail.ToString('HH:mm:ss.fff') } else { 'none' }
    last_failure    = if ($lastFail) { $lastFail.ToString('HH:mm:ss.fff') } else { 'none' }
    recovered_at    = if ($recovered) { $recovered.ToString('HH:mm:ss.fff') } else { 'not recovered' }
    outage_ms       = if ($recovered) { [int]($recovered - $firstFail).TotalMilliseconds } else { -1 }
    successful_reads_after_failure = $okAfterFail
}
Add-Content -Path $Log -Value ('summary        ' + ($summary | ConvertTo-Json -Compress)) -Encoding utf8
