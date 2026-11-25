# Back up the AFS MySQL lab database with mysqldump, then prune old copies.
# Runs unattended from Task Scheduler ("AFS MySQL Backup").
#
# The password never appears on a command line: it is written to a temporary
# client options file (--defaults-extra-file) that is deleted in a finally
# block. The dump is validated by looking for the expected table definition,
# because a zero-byte or truncated dump is the classic silent failure.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$MysqlHome  = 'C:\Program Files\MySQL\MySQL Server 8.4',
  [string]$BackupRoot = 'C:\ProgramData\AFS\backups\mysql',
  [string]$Database   = 'afs_lab',
  [string]$HostName   = '127.0.0.1',
  [int]$Port          = 3306,
  [int]$KeepDays      = 7
)
$ErrorActionPreference = 'Stop'
$dumpExe = Join-Path $MysqlHome 'bin\mysqldump.exe'
$secretPath = Join-Path (Get-Location) '.secrets\mysql_backup_password.txt'

if (-not (Test-Path -LiteralPath $dumpExe)) { throw "mysqldump.exe not found: $dumpExe" }
if (-not (Test-Path -LiteralPath $secretPath)) { throw "missing $secretPath - create the afs_backup user first" }
$pw = (Get-Content -LiteralPath $secretPath -Raw).Trim()

New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dumpPath = Join-Path $BackupRoot ("{0}_{1}.sql" -f $Database, $stamp)

$cnf = Join-Path $env:TEMP ("afs_mysql_backup_{0}.cnf" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
Set-Content -LiteralPath $cnf -Encoding ASCII -Value @(
  '[client]',
  'user=afs_backup',
  "password=$pw",
  "host=$HostName",
  "port=$Port"
)

$nativePref = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $out = & $dumpExe "--defaults-extra-file=$cnf" --single-transaction --routines --triggers --events --databases $Database "--result-file=$dumpPath" 2>&1 | Out-String
  $code = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $nativePref
  Remove-Item -LiteralPath $cnf -Force -ErrorAction SilentlyContinue
}
$out = $out.Replace($pw, '********')
if ($code -ne 0) { Write-Host $out; throw "mysqldump failed with exit code $code" }

$size = (Get-Item -LiteralPath $dumpPath).Length
if ($size -lt 2048) { throw "dump is only $size bytes - treating it as a failed backup" }
$head = Get-Content -LiteralPath $dumpPath -TotalCount 200 -ErrorAction SilentlyContinue
if (-not ($head -match 'CREATE TABLE `account`')) { throw 'dump does not contain the expected account table' }

# Retention: keep the newest KeepDays files.
$old = Get-ChildItem -LiteralPath $BackupRoot -Filter '*.sql' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -Skip $KeepDays
foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force }

$latest = Get-ChildItem -LiteralPath $BackupRoot -Filter '*.sql' | Sort-Object LastWriteTime -Descending
Write-Host ("backup written: {0} ({1:N0} bytes)" -f $dumpPath, $size)
Write-Host ("copies retained: {0} (newest {1})" -f $latest.Count, $latest[0].Name)
