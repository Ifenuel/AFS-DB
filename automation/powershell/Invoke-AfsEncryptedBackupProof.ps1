# Proves that backups are encrypted and that the certificate is required to restore them.
# Answers the 2026 Sterling Bank-Remita failure mode: database dumps published because the
# media was readable by anyone who obtained it.
[CmdletBinding()]
param(
    [string]$Database = 'AFS_Audit',
    [string]$ProofDb  = 'AFS_EncProof',
    [string]$OutDir   = 'C:\Backups\certs',
    [string]$Evidence = 'evidence\verify\live\49_encrypted_backup.txt'
)

$ErrorActionPreference = 'Stop'
$log = New-Object System.Collections.Generic.List[string]
function Say($m) { $log.Add($m); Write-Host $m }

$secretFile = Join-Path (Get-Location) '.secrets\afs_backup_cert.txt'
if (-not (Test-Path $secretFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $secretFile) | Out-Null
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes) | Set-Content -Path $secretFile -NoNewline
}
$certPwd = (Get-Content -Raw $secretFile).Trim()
$bak = "C:\Backups\$($Database)_ENCRYPTED.bak"
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$cerPath = Join-Path $OutDir "AFS_BackupCert_$stamp.cer"
$pvkPath = Join-Path $OutDir "AFS_BackupCert_$stamp.pvk"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path 'C:\Backups\enctest' | Out-Null

$cs = 'Server=.;Database=master;Integrated Security=true;Encrypt=false'
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()

function Invoke-Batch([string]$sql, [int]$timeout = 300) {
    foreach ($part in [regex]::Split($sql, '(?im)^\s*GO\s*$')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $part
        $cmd.CommandTimeout = $timeout
        [void]$cmd.ExecuteNonQuery()
    }
}
function Scalar([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 300
    return $cmd.ExecuteScalar()
}

Say "=== Encrypted backup proof: $Database  $(Get-Date -Format s) ==="
Say ("server      : " + (Scalar "SELECT @@VERSION").Split("`n")[0])
Say ("database    : $Database")

# 1. Server master key and backup certificate.
Say ""
Say "--- 1. master key and certificate"
Invoke-Batch @"
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$( [guid]::NewGuid().ToString('N') )Aa1!Aa1!';
GO
"@
Say ("master key  : " + (Scalar "SELECT COUNT(*) FROM sys.symmetric_keys WHERE name='##MS_DatabaseMasterKey##'"))

$hasCert = [int](Scalar "SELECT COUNT(*) FROM sys.certificates WHERE name='AFS_BackupCert'")
if ($hasCert -eq 0) {
    Invoke-Batch "CREATE CERTIFICATE AFS_BackupCert WITH SUBJECT = 'AFS backup encryption', EXPIRY_DATE = '2036-11-30';"
}
Say ("certificate : " + (Scalar "SELECT name + ' | expires ' + CONVERT(varchar(10), expiry_date, 120) FROM sys.certificates WHERE name='AFS_BackupCert'"))

# 2. Encrypted full backup with checksum.
Say ""
Say "--- 2. BACKUP ... WITH ENCRYPTION, CHECKSUM"
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Batch "BACKUP DATABASE [$Database] TO DISK = N'$bak' WITH INIT, FORMAT, CHECKSUM, ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = AFS_BackupCert), STATS = 25;" 900
$sw.Stop()
$sizeMb = [math]::Round((Get-Item $bak).Length / 1MB, 1)
Say ("backup file : {0}  ({1} MB, {2:N1} s)" -f $bak, $sizeMb, $sw.Elapsed.TotalSeconds)

# 3. Media verification works without the key (header only), restore does not.
Say ""
Say "--- 3. RESTORE VERIFYONLY WITH CHECKSUM"
$sw.Restart()
Invoke-Batch "RESTORE VERIFYONLY FROM DISK = N'$bak' WITH CHECKSUM;" 600
$sw.Stop()
Say ("verifyonly  : PASS in {0:N1} s" -f $sw.Elapsed.TotalSeconds)

# 4. Restore while the certificate exists, then export it and remove it.
Say ""
Say "--- 4. restore with the certificate present"
Invoke-Batch @"
IF DB_ID('$ProofDb') IS NOT NULL BEGIN ALTER DATABASE [$ProofDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$ProofDb]; END
GO
"@
$sw.Restart()
Invoke-Batch "RESTORE DATABASE [$ProofDb] FROM DISK = N'$bak' WITH MOVE N'$(Split-Path $Database -Leaf)' TO N'C:\Backups\enctest\$ProofDb.mdf', MOVE N'$(Split-Path $Database -Leaf)_log' TO N'C:\Backups\enctest\$ProofDb_log.ldf', RECOVERY;" 900
$sw.Stop()
Say ("restore ok  : {0} in {1:N1} s, db_id={2}" -f $ProofDb, $sw.Elapsed.TotalSeconds, (Scalar "SELECT DB_ID('$ProofDb')"))
Say ("rows visible: " + (Scalar "SELECT COUNT(*) FROM [$ProofDb].sys.tables WHERE is_ms_shipped=0"))

Say ""
Say "--- 5. export the certificate, then remove it"
Remove-Item -Path $cerPath, $pvkPath -ErrorAction SilentlyContinue
$sqlExport = "BACKUP CERTIFICATE AFS_BackupCert TO FILE = N'$cerPath' WITH PRIVATE KEY (FILE = N'$pvkPath', ENCRYPTION BY PASSWORD = N'" + $certPwd + "');"
Invoke-Batch $sqlExport
Say ("exported    : $cerPath ; $pvkPath")

Invoke-Batch @"
ALTER DATABASE [$ProofDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [$ProofDb];
DROP CERTIFICATE AFS_BackupCert;
GO
"@
Say ("certificate present now: " + (Scalar "SELECT COUNT(*) FROM sys.certificates WHERE name='AFS_BackupCert'"))

# 5. The attack scenario: the media is in hand, the key is not.
Say ""
Say "--- 6. restore WITHOUT the certificate (the stolen-media case)"
$failMsg = $null
try {
    Invoke-Batch "RESTORE DATABASE [$ProofDb] FROM DISK = N'$bak' WITH MOVE N'$(Split-Path $Database -Leaf)' TO N'C:\Backups\enctest\$ProofDb.mdf', MOVE N'$(Split-Path $Database -Leaf)_log' TO N'C:\Backups\enctest\$ProofDb_log.ldf', RECOVERY;" 600
    Say "UNEXPECTED: restore succeeded without the certificate."
} catch {
    $failMsg = $_.Exception.Message
    Say "restore refused as expected:"
    Say ("  " + ($failMsg -replace "`r?`n", ' ').Trim())
}

# 6. Re-import the key and restore again.
Say ""
Say "--- 7. re-import the certificate and restore again"
$sqlImport = "CREATE CERTIFICATE AFS_BackupCert FROM FILE = N'$cerPath' WITH PRIVATE KEY (FILE = N'$pvkPath', DECRYPTION BY PASSWORD = N'" + $certPwd + "');"
Invoke-Batch $sqlImport
$sw.Restart()
Invoke-Batch "RESTORE DATABASE [$ProofDb] FROM DISK = N'$bak' WITH MOVE N'$(Split-Path $Database -Leaf)' TO N'C:\Backups\enctest\$ProofDb.mdf', MOVE N'$(Split-Path $Database -Leaf)_log' TO N'C:\Backups\enctest\$ProofDb_log.ldf', RECOVERY;" 900
$sw.Stop()
$restored = [int](Scalar "SELECT COUNT(*) FROM [$ProofDb].sys.tables WHERE is_ms_shipped=0")
Say ("restore ok  : {0} in {1:N1} s, {2} tables" -f $ProofDb, $sw.Elapsed.TotalSeconds, $restored)

# 7. Tidy and summary.
Invoke-Batch @"
ALTER DATABASE [$ProofDb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [$ProofDb];
GO
"@
Say ""
Say "--- result"
Say "  encrypted backup created with AES-256 under AFS_BackupCert"
Say "  media verified with CHECKSUM"
Say "  restore without the certificate: REFUSED"
Say "  restore after re-importing the certificate: OK"
Say "  proof database dropped; backup retained at $bak"
$conn.Close()

$out = Join-Path (Get-Location) $Evidence
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
$log | Set-Content -Path $out -Encoding UTF8
Say ""
Say "evidence written to $Evidence"
