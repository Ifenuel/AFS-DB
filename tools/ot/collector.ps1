# Historian collector.
#
# Reads three holding registers from the PLC over Modbus TCP once per second and
# writes one row per tag into AFS_Archive.telemetry.Reading. When a poll fails it
# records the window once the plant answers again, so a gap in coverage is data,
# not an absence of data.
param(
    [string]$Server = '.',
    [string]$Database = 'AFS_Archive',
    [string]$PlcHost = '127.0.0.1',
    [int]$PlcPort = 15020,
    [int]$RunSeconds = 70,
    [int]$IntervalMs = 1000,
    [string]$Log = 'C:\Backups\ha\telemetry_collector.log'
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$m) {
    $line = '{0:HH:mm:ss.fff}  {1}' -f (Get-Date), $m
    Add-Content -Path $Log -Value $line -Encoding utf8
}

Set-Content -Path $Log -Value '' -Encoding utf8

function New-Conn {
    $cs = "Server=$Server;Database=$Database;Integrated Security=True;Encrypt=False;Connect Timeout=5;Application Name=AFS-Historian"
    return New-Object System.Data.SqlClient.SqlConnection($cs)
}

function Read-Registers([int]$count) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect($PlcHost, $PlcPort)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 700
        $transaction = [uint16](Get-Random -Minimum 1 -Maximum 60000)
        $request = [byte[]]@(
            [byte](($transaction -shr 8) -band 0xFF), [byte]($transaction -band 0xFF),
            0, 0, 0, 6, 1, 3,
            0, 0,
            [byte](($count -shr 8) -band 0xFF), [byte]($count -band 0xFF)
        )
        $stream.Write($request, 0, $request.Length)
        $header = New-Object byte[] 7
        $read = 0
        while ($read -lt 7) {
            $n = $stream.Read($header, $read, 7 - $read)
            if ($n -le 0) { throw 'PLC closed the connection' }
            $read += $n
        }
        $length = ([int]$header[4] -shl 8) -bor [int]$header[5]
        $body = New-Object byte[] ($length - 1)
        $read = 0
        while ($read -lt $body.Length) {
            $n = $stream.Read($body, $read, $body.Length - $read)
            if ($n -le 0) { throw 'PLC closed the connection' }
            $read += $n
        }
        if ($body[0] -ne 3) { throw "unexpected function code $($body[0])" }
        $values = @()
        for ($i = 0; $i -lt $count; $i++) {
            $values += (([int]$body[2 + $i * 2] -shl 8) -bor [int]$body[3 + $i * 2])
        }
        return $values
    } finally {
        $client.Close()
    }
}

$tags = @()
$conn = New-Conn
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = 'SELECT TagId, TagCode, PlcRegister, Unit FROM telemetry.Tag ORDER BY PlcRegister'
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
        $tags += [pscustomobject]@{
            id = [int]$reader['TagId']; code = [string]$reader['TagCode']
            register = [int]$reader['PlcRegister']; unit = [string]$reader['Unit']
        }
    }
    $reader.Close()

    $cmd = $conn.CreateCommand()
    $cmd.CommandText = 'INSERT INTO telemetry.CollectorRun (StartedAt, IntervalMs, Notes) VALUES (SYSUTCDATETIME(), @ms, @notes); SELECT CAST(SCOPE_IDENTITY() AS int);'
    $cmd.Parameters.AddWithValue('@ms', $IntervalMs) | Out-Null
    $cmd.Parameters.AddWithValue('@notes', "Modbus TCP $PlcHost`:$PlcPort") | Out-Null
    $runId = [int]$cmd.ExecuteScalar()

    $insert = $conn.CreateCommand()
    $insert.CommandText = 'INSERT INTO telemetry.Reading (TagId, ObservedAt, Value, Quality) VALUES (@tag, @at, @value, 192)'
    $pTag = $insert.Parameters.Add('@tag', [System.Data.SqlDbType]::SmallInt)
    $pAt = $insert.Parameters.Add('@at', [System.Data.SqlDbType]::DateTime2)
    $pAt.Scale = 3
    $pValue = $insert.Parameters.Add('@value', [System.Data.SqlDbType]::Decimal)
    $pValue.Precision = 10; $pValue.Scale = 3

    $gapInsert = $conn.CreateCommand()
    $gapInsert.CommandText = 'INSERT INTO telemetry.Gap (RunId, TagId, GapStart, GapEnd, MissedReadings) VALUES (@run, NULL, @start, @finish, @missed)'
    $gapInsert.Parameters.AddWithValue('@run', $runId) | Out-Null
    $pGapStart = $gapInsert.Parameters.Add('@start', [System.Data.SqlDbType]::DateTime2)
    $pGapStart.Scale = 3
    $pGapEnd = $gapInsert.Parameters.Add('@finish', [System.Data.SqlDbType]::DateTime2)
    $pGapEnd.Scale = 3
    $gapInsert.Parameters.AddWithValue('@missed', 0) | Out-Null

    Write-Log "collector start  run=$runId  tags=$($tags.Count)  interval=${IntervalMs}ms  target=${PlcHost}:${PlcPort}"
    $written = 0
    $gaps = 0
    $failures = 0
    $gapStart = $null
    $lastFailure = $null
    $deadline = (Get-Date).AddSeconds($RunSeconds)

    while ((Get-Date) -lt $deadline) {
        $tick = Get-Date
        try {
            $values = Read-Registers $tags.Count
            foreach ($tag in $tags) {
                $raw = $values[$tag.register]
                $pTag.Value = $tag.id
                $pAt.Value = [DateTime]::UtcNow
                $pValue.Value = [decimal]($raw / 100.0)
                $insert.ExecuteNonQuery() | Out-Null
                $written++
            }
            if ($gapStart) {
                $seconds = [math]::Round(((Get-Date) - $gapStart).TotalSeconds, 1)
                $missed = [int][math]::Max(1, [math]::Round($seconds * 1000 / $IntervalMs) - 1)
                $pGapStart.Value = $gapStart.ToUniversalTime()
                $pGapEnd.Value = [DateTime]::UtcNow
                $gapInsert.Parameters['@missed'].Value = $missed
                $gapInsert.ExecuteNonQuery() | Out-Null
                $gaps++
                Write-Log "gap recorded     $seconds s without a reading, $missed missed samples"
                $gapStart = $null
                $failures = 0
            }
        } catch {
            $failures++
            if (-not $gapStart) {
                $gapStart = Get-Date
                $lastFailure = $_.Exception.Message.Split("`n")[0].Trim()
                Write-Log "plant unreachable $lastFailure"
            }
        }
        $elapsed = ((Get-Date) - $tick).TotalMilliseconds
        $sleep = [int][math]::Max(0, $IntervalMs - $elapsed)
        Start-Sleep -Milliseconds $sleep
    }

    $update = $conn.CreateCommand()
    $update.CommandText = 'UPDATE telemetry.CollectorRun SET EndedAt = SYSUTCDATETIME(), ReadingsWritten = @r, GapsDetected = @g WHERE RunId = @id'
    $update.Parameters.AddWithValue('@r', $written) | Out-Null
    $update.Parameters.AddWithValue('@g', $gaps) | Out-Null
    $update.Parameters.AddWithValue('@id', $runId) | Out-Null
    $update.ExecuteNonQuery() | Out-Null

    Write-Log "collector stop   run=$runId  readings=$written  gaps=$gaps"
    Write-Log "summary          run=$runId readings=$written gaps=$gaps interval_ms=$IntervalMs"
} finally {
    $conn.Dispose()
}
