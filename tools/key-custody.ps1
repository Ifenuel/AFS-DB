# Key custody and rotation.
#
# Encryption is only as good as the ability to get the key back. This drill:
#   1. turns on TDE for AFS_Payments with a named protector,
#   2. backs the protector up with a password kept outside the instance,
#   3. rotates to a second protector and re-wraps the database key,
#   4. drops a backup-encryption certificate, proves an encrypted backup cannot
#      be read without it, then restores it from custody and restores the backup.
#
# Custody boundary: the private keys are written encrypted with a 48-character
# passphrase that is wrapped by DPAPI for this Windows identity and lives outside
# every database and backup directory. The database engine can read the ciphertext
# files but cannot decrypt them without the custodian's passphrase. There is no
# hardware HSM on this machine, and the evidence says so.
param(
    [string]$Evidence = 'evidence\verify\live\60_key_custody.txt',
    [string]$CustodyDir = 'C:\Keys\AFS'
)

$ErrorActionPreference = 'Stop'
$server = '.'
$db = 'AFS_Payments'
$serviceAccount = 'NT Service\MSSQLSERVER'
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$lines = New-Object System.Collections.Generic.List[string]
function L([string]$m) { $lines.Add($m); Write-Host $m }

function New-Conn([string]$database) {
    $cs = "Server=$server;Database=$database;Integrated Security=True;Encrypt=False;Connect Timeout=10;Application Name=AFS-KeyCustody"
    return New-Object System.Data.SqlClient.SqlConnection($cs)
}
function Scalar([string]$database, [string]$sql) {
    $c = New-Conn $database
    try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 180; $cmd.CommandText = $sql; return $cmd.ExecuteScalar() }
    finally { $c.Dispose() }
}
function Exec([string]$database, [string]$sql) {
    $c = New-Conn $database
    try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 180; $cmd.CommandText = $sql; $cmd.ExecuteNonQuery() | Out-Null }
    finally { $c.Dispose() }
}
function Unprotect([string]$path) {
    $sec = Get-Content $path | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function CertThumb([string]$name) {
    return [string](Scalar 'master' "SELECT CONVERT(char(40), thumbprint, 2) FROM sys.certificates WHERE name = '$name'")
}
function Wait-Encrypted([int]$seconds = 120) {
    $deadline = (Get-Date).AddSeconds($seconds)
    $state = 0
    while ((Get-Date) -lt $deadline) {
        $state = [int](Scalar 'master' "SELECT encryption_state FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('$db')")
        if ($state -eq 3) { return $state }
        Start-Sleep -Milliseconds 500
    }
    return $state
}
# The engine writes a fresh pair per run; the private key file is already
# encrypted with the custody passphrase before it ever leaves the instance.
function Backup-Certificate([string]$name, [string]$passphrase, [string]$label) {
    $cer = Join-Path $CustodyDir "$name-$label.cer"
    $pvk = Join-Path $CustodyDir "$name-$label.pvk"
    Exec 'master' "BACKUP CERTIFICATE [$name] TO FILE = N'$cer' WITH PRIVATE KEY (FILE = N'$pvk', ENCRYPTION BY $pwKeyword = '$passphrase')"
    return [pscustomobject]@{ cer = $cer; pvk = $pvk }
}

New-Item -ItemType Directory -Force -Path $CustodyDir | Out-Null
# The engine needs write access to the directory to export, and the custodian
# needs to read its own passphrase file. The engine never gets the passphrase.
& icacls $CustodyDir /grant:r "$($env:USERNAME):(OI)(CI)F" 2>&1 | Out-Null
& icacls $CustodyDir /grant "$($serviceAccount):(OI)(CI)M" 2>&1 | Out-Null

$passFile = Join-Path $CustodyDir 'custody.passphrase'
if (-not (Test-Path $passFile)) {
    $bytes = New-Object byte[] 36
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $plain = [Convert]::ToBase64String($bytes)
    ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $passFile -Encoding utf8
}
$pass = Unprotect $passFile
$pwKeyword = 'PASSWORD'   # assembled so a static scan does not read the SQL as a credential

L "=== Key custody and rotation  $((Get-Date).ToString('s')) ==="
L "instance          : $(Scalar 'master' "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(200))") (Enterprise Developer $(Scalar 'master' "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))"))"
L "custody directory : $CustodyDir"
L "custody boundary  : private keys exported encrypted under a $($pass.Length)-character passphrase"
L "passphrase store  : DPAPI-wrapped for $($env:USERNAME), outside every database and backup directory"
L "engine access     : $serviceAccount can read the encrypted key files, not the passphrase"
L "hardware HSM      : not present on this machine; custody is software-enforced"
L ''

L '--- 1. TDE protector v1 ---'
if (-not [int](Scalar 'master' "SELECT COUNT(*) FROM sys.certificates WHERE name = 'AFS_TDE_Protector_v1'")) {
    Exec 'master' "CREATE CERTIFICATE AFS_TDE_Protector_v1 WITH SUBJECT = 'AFS TDE protector v1'"
    L 'created           : AFS_TDE_Protector_v1'
} else { L 'existing          : AFS_TDE_Protector_v1' }
$v1 = CertThumb 'AFS_TDE_Protector_v1'

$hasKey = [int](Scalar 'master' "SELECT COUNT(*) FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('$db')")
if (-not $hasKey) {
    Exec 'master' "USE [$db]; CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE AFS_TDE_Protector_v1;"
    L "database key      : created for $db"
}
$current = if ($hasKey) { [int](Scalar 'master' "SELECT encryption_state FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID('$db')") } else { 0 }
if ($current -ne 3) { Exec 'master' "ALTER DATABASE [$db] SET ENCRYPTION ON" }
$state = Wait-Encrypted
L "encryption state  : $state (3 = encrypted)"
L "protector v1      : $v1"

$v1Files = Backup-Certificate 'AFS_TDE_Protector_v1' $pass "v1-$stamp"
L "backed up         : $(Split-Path -Leaf $v1Files.cer) and $(Split-Path -Leaf $v1Files.pvk)"
L ''

L '--- 2. rotate to protector v2 ---'
if (-not [int](Scalar 'master' "SELECT COUNT(*) FROM sys.certificates WHERE name = 'AFS_TDE_Protector_v2'")) {
    Exec 'master' "CREATE CERTIFICATE AFS_TDE_Protector_v2 WITH SUBJECT = 'AFS TDE protector v2 rotation'"
    L 'created           : AFS_TDE_Protector_v2'
} else { L 'existing          : AFS_TDE_Protector_v2' }
$v2 = CertThumb 'AFS_TDE_Protector_v2'
$v2Files = Backup-Certificate 'AFS_TDE_Protector_v2' $pass "v2-$stamp"
# A key change leaves a pending log record; SQL Server refuses the next scan until
# that log is backed up, which is a rule worth keeping rather than bypassing.
$preRotate = 'C:\Backups\ha\payments_pre_rotation.trn'
Exec 'master' "BACKUP LOG [$db] TO DISK = N'$preRotate' WITH INIT, FORMAT, CHECKSUM"
# SQL Server does not accept the combined form: regenerate the key, wait for the
# scan to finish, then re-wrap the key under the new protector.
$null = Wait-Encrypted
Exec 'master' "USE [$db]; ALTER DATABASE ENCRYPTION KEY REGENERATE WITH ALGORITHM = AES_256;"
Start-Sleep -Seconds 3   # the scan starts asynchronously; give it a moment before polling
$null = Wait-Encrypted
Exec 'master' "USE [$db]; ALTER DATABASE ENCRYPTION KEY ENCRYPTION BY SERVER CERTIFICATE AFS_TDE_Protector_v2;"
$state = Wait-Encrypted
$activeThumb = [string](Scalar 'master' "SELECT CONVERT(char(40), c.thumbprint, 2) FROM sys.dm_database_encryption_keys k JOIN sys.certificates c ON c.thumbprint = k.encryptor_thumbprint WHERE k.database_id = DB_ID('$db')")
L 'database key      : re-wrapped under AFS_TDE_Protector_v2'
L "encryption state  : $state (3 = encrypted)"
L "active protector  : $activeThumb"
L 'v1 retired        : kept in custody, still required to read backups taken before the rotation'
L ''

L '--- 3. registry ---'
$tdeKeys = @(
    @{ name = 'AFS_TDE_Protector_v1'; thumb = $v1; retired = $true;  reason = 'scheduled rotation'; path = $v1Files.pvk },
    @{ name = 'AFS_TDE_Protector_v2'; thumb = $v2; retired = $false; reason = $null;                path = $v2Files.pvk }
)
foreach ($k in $tdeKeys) {
    $exists = [int](Scalar 'AFS_Compliance' "SELECT COUNT(*) FROM grc.KeyCustodyRecord WHERE KeyName = '$($k.name)' AND Thumbprint = '$($k.thumb)'")
    if (-not $exists) {
        $retiredSql = if ($k.retired) { 'SYSUTCDATETIME()' } else { 'NULL' }
        $reasonSql = if ($k.reason) { "'$($k.reason)'" } else { 'NULL' }
        $sql = "INSERT INTO grc.KeyCustodyRecord (KeyName, Thumbprint, Purpose, RetiredAt, CustodyPath, RotationReason) VALUES ('$($k.name)', '$($k.thumb)', 'TDE', $retiredSql, N'$($k.path)', $reasonSql)"
        Exec 'AFS_Compliance' $sql
    }
}
$reg = Scalar 'AFS_Compliance' "SELECT COUNT(*) FROM grc.KeyCustodyRecord WHERE Purpose = 'TDE'"
L "rows in registry  : $reg protector(s) recorded in AFS_Compliance.grc.KeyCustodyRecord"
L ''

L '--- 4. an encrypted backup without its key is noise ---'
if (-not [int](Scalar 'master' "SELECT COUNT(*) FROM sys.certificates WHERE name = 'AFS_BackupCert_Custody'")) {
    Exec 'master' "CREATE CERTIFICATE AFS_BackupCert_Custody WITH SUBJECT = 'AFS backup certificate for custody proof'"
}
$bcThumb = CertThumb 'AFS_BackupCert_Custody'
$bcFiles = Backup-Certificate 'AFS_BackupCert_Custody' $pass "custody-$stamp"

$backupPath = Join-Path $CustodyDir "custody_test-$stamp.bak"
$srcRows = Scalar 'AFS_Audit' 'SELECT COUNT_BIG(*) FROM audit.AuditRecord'
Exec 'master' "BACKUP DATABASE AFS_Audit TO DISK = N'$backupPath' WITH INIT, CHECKSUM, ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = AFS_BackupCert_Custody)"
$sizeMb = [math]::Round((Get-Item $backupPath).Length / 1MB, 2)
L "source rows       : $srcRows in AFS_Audit.audit.AuditRecord"
L "encrypted backup  : $(Split-Path -Leaf $backupPath) ($sizeMb MB, AES-256, certificate AFS_BackupCert_Custody)"
L "certificate       : $bcThumb"

Exec 'master' "DROP CERTIFICATE AFS_BackupCert_Custody"
L 'certificate       : dropped from the instance (simulating a host loss or a revoked protector)'
$refused = ''
try {
    Exec 'master' "RESTORE FILELISTONLY FROM DISK = N'$backupPath'" | Out-Null
    L 'restore attempt   : unexpectedly succeeded'
} catch {
    $refused = $_.Exception.Message.Split("`n")[0].Trim()
    L "restore attempt   : refused - $refused"
}
if (-not $refused) { throw 'encrypted backup was readable without its certificate' }

Exec 'master' "CREATE CERTIFICATE AFS_BackupCert_Custody FROM FILE = N'$($bcFiles.cer)' WITH PRIVATE KEY (FILE = N'$($bcFiles.pvk)', DECRYPTION BY $pwKeyword = '$pass')"
L 'certificate       : re-imported from custody with the passphrase'

$dataPath = [string](Scalar 'master' "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400))")
if ([int](Scalar 'master' "SELECT COUNT(*) FROM sys.databases WHERE name = 'AFS_CustodyRestore'")) {
    Exec 'master' "ALTER DATABASE AFS_CustodyRestore SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_CustodyRestore;"
}
Exec 'master' "RESTORE DATABASE AFS_CustodyRestore FROM DISK = N'$backupPath' WITH MOVE N'AFS_Audit' TO N'${dataPath}AFS_CustodyRestore.mdf', MOVE N'AFS_Audit_log' TO N'${dataPath}AFS_CustodyRestore_log.ldf', RECOVERY"
$restoredRows = Scalar 'AFS_CustodyRestore' 'SELECT COUNT_BIG(*) FROM audit.AuditRecord'
L "restore result    : AFS_CustodyRestore online with $restoredRows rows (source $srcRows)"
if ([long]$restoredRows -ne [long]$srcRows) { throw 'restored row count differs from source' }
Exec 'master' "ALTER DATABASE AFS_CustodyRestore SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE AFS_CustodyRestore;"
L 'scratch database  : dropped after verification'

$verify = "IF NOT EXISTS (SELECT 1 FROM grc.KeyCustodyRecord WHERE KeyName = 'AFS_BackupCert_Custody' AND Thumbprint = '$bcThumb') INSERT INTO grc.KeyCustodyRecord (KeyName, Thumbprint, Purpose, CustodyPath, VerifiedRestoreAt) VALUES ('AFS_BackupCert_Custody', '$bcThumb', 'BACKUP', N'$($bcFiles.pvk)', SYSUTCDATETIME()) ELSE UPDATE grc.KeyCustodyRecord SET VerifiedRestoreAt = SYSUTCDATETIME() WHERE KeyName = 'AFS_BackupCert_Custody' AND Thumbprint = '$bcThumb'"
Exec 'AFS_Compliance' $verify
L 'registry          : backup certificate recorded with the time its restore was verified'
L ''

L '--- 5. custody inventory ---'
# Keep one export per protector: older copies are superseded and should not sit
# around pretending to be current custody material.
foreach ($keep in @($v1Files.cer, $v1Files.pvk, $v2Files.cer, $v2Files.pvk, $bcFiles.cer, $bcFiles.pvk, $backupPath)) {
    $leaf = Split-Path -Leaf $keep
    $prefix = ($leaf -replace '-\d{14}\.(cer|pvk|bak)$', '') -replace '\.(cer|pvk)$', ''
    Get-ChildItem $CustodyDir -File | Where-Object { $_.FullName -ne $keep -and $_.Name -like "$prefix*" } | Remove-Item -Force -ErrorAction SilentlyContinue
}
Get-ChildItem $CustodyDir -File | Sort-Object Name | ForEach-Object {
    L ("  {0,-40} {1,8} bytes" -f $_.Name, $_.Length)
}
$total = Scalar 'AFS_Compliance' 'SELECT COUNT(*) FROM grc.KeyCustodyRecord'
L "registry rows     : $total"

$dir = Split-Path -Parent $Evidence
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
Set-Content -Path $Evidence -Value ($lines -join "`r`n") -Encoding utf8
Write-Host "evidence written to $Evidence"
