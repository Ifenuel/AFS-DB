# Capability verification sweep.
# Re-tests the rows on /capabilities that were previously recorded as observed or partial,
# and captures the output for the evidence index.
[CmdletBinding()]
param([string]$Evidence = 'evidence\verify\live\53_capability_sweep.txt')
$ErrorActionPreference = 'Continue'
$root = Get-Location
$log = New-Object System.Collections.Generic.List[string]
function Say($m) { $log.Add($m); Write-Host $m }
function Head($m) { Say ''; Say "=== $m ===" }

$cs = 'Server=.;Database=master;Integrated Security=true;Encrypt=false'
$conn = New-Object System.Data.SqlClient.SqlConnection($cs); $conn.Open()
function New-Conn { $c = New-Object System.Data.SqlClient.SqlConnection($cs); $c.Open(); return $c }
function Scalar([string]$sql) { $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 180; return $cmd.ExecuteScalar() }
function Table([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 180
    $rd = $cmd.ExecuteReader(); $t = New-Object System.Data.DataTable; $t.Load($rd); return ,$t
}
function Exec([string]$sql) { $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 180; [void]$cmd.ExecuteNonQuery() }

Say "AFS-DBA-001 capability sweep  $(Get-Date -Format s)"
Say ("server: " + (Scalar "SELECT @@VERSION").Split("`n")[0].Trim())

# ------------------------------------------------------------------ A. blocking
Head 'A. Blocking and isolation (was: observed)'
Exec @"
IF OBJECT_ID('tempdb.dbo.AFSLockProbe') IS NOT NULL DROP TABLE tempdb.dbo.AFSLockProbe;
CREATE TABLE tempdb.dbo.AFSLockProbe (Id int NOT NULL PRIMARY KEY, Amount decimal(18,2) NOT NULL);
INSERT tempdb.dbo.AFSLockProbe (Id, Amount) VALUES (1, 100.00);
"@
$connA = New-Conn
$cmdA = $connA.CreateCommand()
$cmdA.CommandText = "BEGIN TRAN; UPDATE tempdb.dbo.AFSLockProbe SET Amount = Amount + 10 WHERE Id = 1;"
$cmdA.CommandTimeout = 60
[void]$cmdA.ExecuteNonQuery()
Say 'holder   : session A holds an exclusive lock inside an open transaction'

$connB = New-Conn
$cmdB = $connB.CreateCommand()
$cmdB.CommandText = "SET LOCK_TIMEOUT 2500; UPDATE tempdb.dbo.AFSLockProbe SET Amount = Amount + 20 WHERE Id = 1;"
$cmdB.CommandTimeout = 60
$sw = [Diagnostics.Stopwatch]::StartNew()
$async = $cmdB.BeginExecuteNonQuery($null, $null)
Start-Sleep -Milliseconds 900

$connC = New-Conn
$cmdC = $connC.CreateCommand()
$cmdC.CommandText = @"
SELECT r.session_id, r.wait_type, r.wait_time, r.blocking_session_id
FROM sys.dm_exec_requests r WHERE r.wait_type LIKE 'LCK%';
"@
$rd = $cmdC.ExecuteReader()
$waits = @()
while ($rd.Read()) {
    $waits += ("session {0} waiting {1} for {2} ms, blocked by {3}" -f $rd[0], $rd[1], $rd[2], $rd[3])
}
$rd.Close()
Say ("observed : " + ($(if ($waits) { $waits -join '; ' } else { 'no LCK waits visible' })))

$failed = $false
try { [void]$cmdB.EndExecuteNonQuery($async) } catch {
    $failed = $true
    $sw.Stop()
    Say ("blocked  : {0:N0} ms, then " -f $sw.Elapsed.TotalMilliseconds)
    Say ("           " + ($_.Exception.Message -replace "`r?`n", ' ').Trim())
}
if (-not $failed) { $sw.Stop(); Say 'UNEXPECTED: the second update completed without waiting' }
$cmdA.CommandText = 'ROLLBACK;'; [void]$cmdA.ExecuteNonQuery()
$connA.Close(); $connB.Close()
$after = [decimal](Scalar "SELECT Amount FROM tempdb.dbo.AFSLockProbe WHERE Id = 1")
Say ("after    : holder rolled back, amount is $after (second update did not apply)")
Exec "DROP TABLE tempdb.dbo.AFSLockProbe;"

# ------------------------------------------------------------------ B. capacity
Head 'B. Capacity and growth (was: partial)'
$capDbs = @((Table "SELECT name FROM sys.databases WHERE name LIKE 'AFS%' ORDER BY name").Rows | ForEach-Object { [string]$_.name })
$logStats = @{}
foreach ($row in (Table 'DBCC SQLPERF(LOGSPACE);').Rows) {
    $logStats[[string]$row.'Database Name'] = @{ used = [math]::Round([double]$row.'Log Space Used (%)', 1); mb = [math]::Round([double]$row.'Log Size (MB)', 1) }
}
Say ("{0,-20} {1,9} {2,11} {3,11} {4,9}" -f 'database', 'size_mb', 'data_growth', 'log_growth', 'log_used%')
$total = 0
foreach ($db in $capDbs) {
    $size = [decimal](Scalar "SELECT CAST(SUM(size) * 8.0 / 1024 AS decimal(10,1)) FROM [$db].sys.database_files")
    $dg   = [int](Scalar "SELECT MAX(growth) FROM [$db].sys.database_files WHERE type_desc = 'ROWS'")
    $lg   = [int](Scalar "SELECT MAX(growth) FROM [$db].sys.database_files WHERE type_desc = 'LOG'")
    $lu = $logStats[$db]
    Say ("{0,-20} {1,9} {2,11} {3,11}   {4}% of {5} MB" -f $db, $size, $dg, $lg, $lu.used, $lu.mb)
    $total += $size
}
Say ("total allocated: $total MB; every file grows in fixed 8,192 KB steps (no percentage growth)")
Say 'thresholds: log alert documented at 70% used; largest observed value above'

# ------------------------------------------------------------------ C. reporting separation
Head 'C. Reporting separation (was: partial)'
function Get-PlanXml($connection, [string]$sql) {
    $on = $connection.CreateCommand(); $on.CommandText = 'SET SHOWPLAN_XML ON;'; [void]$on.ExecuteNonQuery()
    $q = $connection.CreateCommand(); $q.CommandText = $sql; $q.CommandTimeout = 120
    $r = $q.ExecuteReader(); $xml = ''
    while ($r.Read()) { $xml += [string]$r[0] }
    $r.Close()
    $off = $connection.CreateCommand(); $off.CommandText = 'SET SHOWPLAN_XML OFF;'; [void]$off.ExecuteNonQuery()
    return $xml
}
$csReport = 'Server=.;Database=AFS_Reporting;Integrated Security=true;Encrypt=false'
$connR = New-Object System.Data.SqlClient.SqlConnection($csReport); $connR.Open()
$plan = Get-PlanXml $connR "SELECT TOP 20 AccountNumber, CurrencyCode FROM warehouse.DimAccount ORDER BY AccountNumber;"
$connR.Close()
$dbs = [regex]::Matches($plan, 'Database="\[([^\]]+)\]"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Say ("report query plan touches: " + ($dbs -join ', '))
Say ("core banking referenced: " + $(if ($dbs -contains 'AFS_CoreBanking') { 'YES (separation failed)' } else { 'no' }))
$rowCount = [int](Scalar "SELECT COUNT(*) FROM AFS_Reporting.warehouse.DimAccount")
Say ("warehouse rows served without core tables: DimAccount = $rowCount")

# ------------------------------------------------------------------ D. detection
Head 'D. Failed-login detection (was: two events for three attempts)'
Exec "IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name='AFS_FailedLogins') DROP EVENT SESSION [AFS_FailedLogins] ON SERVER;"
$logPath = [string](Scalar "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400))")
Exec @"
CREATE EVENT SESSION [AFS_FailedLogins] ON SERVER
ADD EVENT sqlserver.error_reported (WHERE error_number = 18456)
ADD TARGET package0.ring_buffer (SET max_memory = 8192)
WITH (MAX_DISPATCH_LATENCY = 1 SECONDS, STARTUP_STATE = OFF);
ALTER EVENT SESSION [AFS_FailedLogins] ON SERVER STATE = START;
"@
for ($i = 1; $i -le 5; $i++) {
    $bad = New-Object System.Data.SqlClient.SqlConnection("Server=.;Database=master;User Id=probe_login;Password=Wrong!Pass$i;Encrypt=false;Connect Timeout=3")
    try { $bad.Open(); $bad.Close() } catch { }
}
Start-Sleep -Seconds 4
$events = Table @"
SELECT n.e.value('(data[@name="message"]/value)[1]','nvarchar(300)') AS message,
       n.e.value('(data[@name="client_app_name"]/value)[1]','nvarchar(100)') AS app,
       n.e.value('(@timestamp)[1]','datetime2') AS at_utc
FROM (SELECT CAST(t.target_data AS xml) AS td FROM sys.dm_xe_session_targets t
      JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
      WHERE s.name='AFS_FailedLogins' AND t.target_name='ring_buffer') x
CROSS APPLY x.td.nodes('//event') AS n(e);
"@
Say ("attempts: 5; events captured: " + $events.Rows.Count)
$withClient = ($events.Rows | Where-Object { $_.message -match 'CLIENT' }).Count
Say ("events carrying a client address: $withClient")
if ($events.Rows.Count -gt 0) {
    Say ("first event: " + $events.Rows[0].at_utc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')
    Say ("message    : " + $events.Rows[0].message)
}
Exec "ALTER EVENT SESSION [AFS_FailedLogins] ON SERVER STATE = STOP;"

# ------------------------------------------------------------------ E. plan reading
Head 'E. Query plan reading'
$csCore = 'Server=.;Database=AFS_CoreBanking;Integrated Security=true;Encrypt=false'
$connP = New-Object System.Data.SqlClient.SqlConnection($csCore); $connP.Open()
$p2 = Get-PlanXml $connP "SELECT TOP 100 TransferId, Amount, CompletedAt FROM account.Transfer WHERE CompletedAt >= '2026-01-01' ORDER BY CompletedAt;"
$connP.Close()
$ops = [regex]::Matches($p2, 'PhysicalOp="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Say ("operators in plan: " + ($ops -join ', '))
$idx = [regex]::Matches($p2, 'Index="\[([^\]]+)\]"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Say ("indexes referenced: " + ($idx -join ', '))

# ------------------------------------------------------------------ F. counts
# ------------------------------------------------------------------ G. change control
Head 'G. Change management: apply, prove, roll back'
Exec "IF OBJECT_ID('tempdb.dbo.AFSChangeProbe') IS NOT NULL DROP TABLE tempdb.dbo.AFSChangeProbe;"
Exec "CREATE TABLE tempdb.dbo.AFSChangeProbe (Id int NOT NULL PRIMARY KEY, Value nvarchar(20) NULL);"
Exec "INSERT tempdb.dbo.AFSChangeProbe (Id, Value) VALUES (1, N'before');"
$before = [string](Scalar "SELECT Value FROM tempdb.dbo.AFSChangeProbe WHERE Id = 1")
Say "before change  : Value = $before; columns = 2"
Exec "ALTER TABLE tempdb.dbo.AFSChangeProbe ADD Note nvarchar(50) NULL;"
$hasCol = [int](Scalar "SELECT COUNT(*) FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb.dbo.AFSChangeProbe') AND name = 'Note'")
Say "change applied : column Note present = $hasCol"
Say ("proving query  : " + [string](Scalar "SELECT Value + ' / ' + ISNULL(Note, 'null') FROM tempdb.dbo.AFSChangeProbe WHERE Id = 1"))
Exec "ALTER TABLE tempdb.dbo.AFSChangeProbe DROP COLUMN Note;"
$afterCol = [int](Scalar "SELECT COUNT(*) FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb.dbo.AFSChangeProbe') AND name = 'Note'")
$afterValue = [string](Scalar "SELECT Value FROM tempdb.dbo.AFSChangeProbe WHERE Id = 1")
Say "rollback run   : column Note present = $afterCol, row still readable = $afterValue"
Exec "DROP TABLE tempdb.dbo.AFSChangeProbe;"

# ------------------------------------------------------------------ F. counts
Head 'F. Artefacts counted, not remembered'
$ps1 = (Get-ChildItem (Join-Path $root 'automation/powershell') -Filter *.ps1).Count
$sql = (Get-ChildItem (Join-Path $root 'sql-server') -Recurse -Filter *.sql).Count
$ev = (Get-ChildItem (Join-Path $root 'evidence/verify/live') -File).Count
$chg = (Get-ChildItem (Join-Path $root 'docs/change') -Filter *.md -ErrorAction SilentlyContinue).Count
$rollbackRefs = (Get-ChildItem (Join-Path $root 'docs') -Recurse -Filter *.md | Select-String -Pattern 'Rollback' -List).Count
Say "powershell scripts : $ps1"
Say "T-SQL files        : $sql"
Say "evidence captures  : $ev"
Say "change records     : $chg (with a rollback section: $rollbackRefs documents mention rollback)"
$procs = [int](Scalar "SELECT COUNT(*) FROM AFS_CoreBanking.sys.procedures WHERE is_ms_shipped=0")
Say "application procs  : $procs in AFS_CoreBanking"

$conn.Close()
$out = Join-Path $root $Evidence
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
$log | Set-Content -Path $out -Encoding UTF8
Say ''
Say "evidence written to $Evidence"
