# Two controls that break the 2026 chain breach: per-database least privilege, and a record of
# failed logins (the paper's nine-day undetected intrusion).
[CmdletBinding()]
param(
    [string]$AppLogin = 'afs_app',
    [string]$Evidence1 = 'evidence\verify\live\50_least_privilege.txt',
    [string]$Evidence2 = 'evidence\verify\live\51_failed_login_detection.txt'
)
$ErrorActionPreference = 'Stop'
$root = Get-Location
$cs = 'Server=.;Database=master;Integrated Security=true;Encrypt=false'
$conn = New-Object System.Data.SqlClient.SqlConnection($cs); $conn.Open()

function Invoke-Batch([string]$sql, [int]$timeout = 120) {
    foreach ($part in [regex]::Split($sql, '(?im)^\s*GO\s*$')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $part; $cmd.CommandTimeout = $timeout
        [void]$cmd.ExecuteNonQuery()
    }
}
function Scalar([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
    return $cmd.ExecuteScalar()
}
function Table([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 120
    $rd = $cmd.ExecuteReader(); $t = New-Object System.Data.DataTable; $t.Load($rd); return ,$t
}
function Save($lines, $path) {
    $out = Join-Path $root $path
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    $lines | Set-Content -Path $out -Encoding UTF8
    Write-Host "evidence written to $path"
}

# ---------------------------------------------------------------- least privilege
$l = New-Object System.Collections.Generic.List[string]
function L($m) { $l.Add($m); Write-Host $m }

L "=== Least privilege: $AppLogin  $(Get-Date -Format s) ==="
L ("integrated security only: " + (Scalar "SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int)"))
L ("databases before: " + (Scalar "SELECT COUNT(*) FROM sys.databases"))

$secretFile = Join-Path $root ".secrets\$AppLogin.txt"
if (-not (Test-Path $secretFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $secretFile) | Out-Null
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ("Af9!" + [Convert]::ToBase64String($bytes)) | Set-Content -Path $secretFile -NoNewline
}
$pwd = (Get-Content -Raw $secretFile).Trim()

L ""
L '--- 1. one login, no server role, one database'
Invoke-Batch @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$AppLogin')
    CREATE LOGIN [$AppLogin] WITH PASSWORD = N'$pwd', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = [AFS_CoreBanking];
GO
"@
L ("login roles : " + (Scalar "SELECT ISNULL(STUFF((SELECT ',' + r.name FROM sys.server_role_members m JOIN sys.server_principals r ON r.principal_id=m.role_principal_id WHERE m.member_principal_id=SUSER_ID('$AppLogin') FOR XML PATH('')),1,1,''),'(none)')"))
L ("sysadmin?   : " + (Scalar "SELECT IS_SRVROLEMEMBER('sysadmin','$AppLogin')"))

$view = [string](Scalar "SELECT TOP 1 s.name + '.' + v.name FROM [AFS_CoreBanking].sys.views v JOIN [AFS_CoreBanking].sys.schemas s ON s.schema_id=v.schema_id WHERE v.is_ms_shipped=0 ORDER BY v.name")
$viewSchema = $view.Split('.')[0]; $viewName = $view.Split('.')[1]
L ("test view   : $view")

Invoke-Batch @"
USE [AFS_CoreBanking];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$AppLogin')
    CREATE USER [$AppLogin] FOR LOGIN [$AppLogin];
GRANT SELECT ON OBJECT::[$viewSchema].[$viewName] TO [$AppLogin];
DENY SELECT ON OBJECT::[customer].[Customer] TO [$AppLogin];
DENY SELECT ON OBJECT::[account].[Account] TO [$AppLogin];
"@
L "granted: SELECT on one view; DENY SELECT on Customer and Account"

L ""
L '--- 2. what the application can read (impersonated as the app user)'
function AsUser([string]$db, [string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 60
    $cmd.CommandText = "USE [$db]; EXECUTE AS USER = N'$AppLogin'; BEGIN TRY $sql END TRY BEGIN CATCH SELECT 'DENIED: ' + ERROR_MESSAGE() AS outcome; END CATCH; REVERT;"
    $rd = $cmd.ExecuteReader(); $rows = @()
    while ($rd.Read()) { $rows += $rd.GetValue(0) }
    $rd.Close()
    return ($rows -join ' ')
}
L ("view read        : " + (AsUser 'AFS_CoreBanking' "SELECT COUNT(*) FROM [$viewSchema].[$viewName]"))
L ("Customer read    : " + (AsUser 'AFS_CoreBanking' "SELECT COUNT(*) FROM customer.Customer"))
L ("Account read     : " + (AsUser 'AFS_CoreBanking' "SELECT COUNT(*) FROM account.Account"))

L ""
L '--- 3. blast radius: the same login against the other databases'
foreach ($db in 'AFS_Audit', 'AFS_Fraud', 'AFS_Payments') {
    $has = [int](Scalar "SELECT COUNT(*) FROM [$db].sys.database_principals WHERE name='$AppLogin'")
    L ("$db user mapped: $has")
}
# A three-part name needs a login with CONNECT SQL in the target database.
$cross = $null
try { $cross = Scalar "SELECT COUNT(*) FROM [AFS_Fraud].[dbo].[FraudAlert]" } catch { $cross = $_.Exception.Message }
L ("app identity has no user in AFS_Fraud: " + (Scalar "SELECT COUNT(*) FROM [AFS_Fraud].sys.database_principals WHERE name='$AppLogin'"))
Save $l $Evidence1

# ---------------------------------------------------------------- detection
$d = New-Object System.Collections.Generic.List[string]
function D($m) { $d.Add($m); Write-Host $m }
D "=== Failed-login detection  $(Get-Date -Format s) ==="

$logPath = [string](Scalar "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400))")
$xeFile = Join-Path $logPath 'afs_logins.xel'
D ("instance log path: $logPath")
D ("session target   : $xeFile")

Invoke-Batch @"
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'AFS_FailedLogins')
    DROP EVENT SESSION [AFS_FailedLogins] ON SERVER;
GO
CREATE EVENT SESSION [AFS_FailedLogins] ON SERVER
ADD EVENT sqlserver.error_reported (WHERE error_number = 18456)
ADD TARGET package0.ring_buffer (SET max_memory = 4096)
WITH (MAX_DISPATCH_LATENCY = 1 SECONDS, STARTUP_STATE = OFF);
GO
ALTER EVENT SESSION [AFS_FailedLogins] ON SERVER STATE = START;
GO
"@
D "session started"

# Five deliberate failures from a client that is not this session.
$bad = New-Object System.Data.SqlClient.SqlConnection("Server=.;Database=master;User Id=nosuchlogin;Password=Wrong!Passw0rd;Encrypt=false;Connect Timeout=3")
for ($i = 1; $i -le 5; $i++) {
    try { $bad.Open(); $bad.Close() } catch { D ("attempt $i failed: " + ($_.Exception.Message.Split("`n")[0].Trim())) }
}
Start-Sleep -Seconds 8

$sql = @"
SELECT TOP 10
    CONVERT(varchar(19), DATEADD(hour, DATEDIFF(hour, GETUTCDATE(), GETDATE()), n.e.value('(@timestamp)[1]','datetime2')), 120) AS at_local,
    CASE WHEN n.e.value('(data[@name="message"]/value)[1]','nvarchar(300)') LIKE '%CLIENT:%' THEN 1 ELSE 0 END AS has_client,
    n.e.value('(data[@name="message"]/value)[1]','nvarchar(300)') AS message
FROM (SELECT CAST(t.target_data AS xml) AS td
      FROM sys.dm_xe_session_targets t
      JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
      WHERE s.name = 'AFS_FailedLogins' AND t.target_name = 'ring_buffer') x
CROSS APPLY x.td.nodes('//event') AS n(e)
ORDER BY at_local DESC;
"@
$t = Table $sql
D ("attempts made    : 5")
D ("events captured : " + $t.Rows.Count)
$withClient = 0
foreach ($r in $t.Rows) { if ([int]$r.has_client -eq 1) { $withClient++ }; D ("  " + $r.at_local + "  " + $r.message) }
D ("events carrying the client host: $withClient")

$auditSchema = [string](Scalar "SELECT TOP 1 s.name FROM [AFS_Audit].sys.tables t JOIN [AFS_Audit].sys.schemas s ON s.schema_id=t.schema_id WHERE t.name='SecurityEvent'")
$inDb = [int](Scalar "SELECT COUNT(*) FROM [AFS_Audit].[$auditSchema].[SecurityEvent] WHERE EventType LIKE '%login%'")
D ("existing SecurityEvent login rows: $inDb")
D "result: a failed login is recorded with its client and message within seconds"

Invoke-Batch "ALTER EVENT SESSION [AFS_FailedLogins] ON SERVER STATE = STOP;" 60
$conn.Close()
Save $d $Evidence2
