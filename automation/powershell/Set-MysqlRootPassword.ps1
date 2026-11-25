# Set (or rotate) the root password of the local AFS MySQL lab instance.
# The instance was initialised with --initialize-insecure, which leaves root
# without a password. The generated password is stored only in
# .secrets/mysql_root_password.txt (gitignored) and is never printed or placed
# on a command line: the ALTER statement goes to the client through stdin.
#
# Re-runnable: if the stored password already works it does nothing; if root is
# still passwordless it sets the stored password; anything else is an error.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$MysqlHome = 'C:\Program Files\MySQL\MySQL Server 8.4',
  [string]$HostName  = '127.0.0.1',
  [int]$Port         = 3306,
  [switch]$Rotate
)
$ErrorActionPreference = 'Stop'
$mysql = Join-Path $MysqlHome 'bin\mysql.exe'
$secretPath = Join-Path (Get-Location) '.secrets\mysql_root_password.txt'

if (-not (Test-Path -LiteralPath $mysql)) { throw "mysql.exe not found: $mysql" }

# Native stderr is not an exception here: mysql writes its password warning to
# stderr, and PowerShell 5.1 would otherwise turn that into a terminating error.
$nativePref = $ErrorActionPreference
function Invoke-Mysql {
  param([string]$Sql, [string]$Password)
  # Local assignment on purpose: a native command reads the calling scope's
  # preference, so setting the script scope here would not be enough.
  $ErrorActionPreference = 'Continue'
  if ($Password) { $env:MYSQL_PWD = $Password } else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
  try {
    if ($Password) { return ($Sql | & $mysql -u root -h $HostName -P $Port 2>&1 | Out-String) }
    return ($Sql | & $mysql -u root --skip-password -h $HostName -P $Port 2>&1 | Out-String)
  } finally {
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
    Set-Variable -Name ErrorActionPreference -Value $nativePref -Scope 0
  }
}

if ($Rotate -or -not (Test-Path -LiteralPath $secretPath)) {
  $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  $body = -join (1..22 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  $pw = "Afs!$body"
  $dir = Split-Path -Parent $secretPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $secretPath -Value $pw -Encoding ASCII -NoNewline
  Write-Host "generated a new root password in $secretPath"
} else {
  $pw = (Get-Content -LiteralPath $secretPath -Raw).Trim()
}

$withStored = Invoke-Mysql -Sql 'SELECT 1;' -Password $pw
if ($withStored -notmatch 'ERROR') {
  Write-Host 'stored root password already works - nothing to change'
} else {
  $withEmpty = Invoke-Mysql -Sql 'SELECT 1;'
  if ($withEmpty -match 'ERROR 1045') {
    throw 'root rejects both the stored password and an empty one - not changing anything'
  }
  $set = Invoke-Mysql -Sql "ALTER USER 'root'@'localhost' IDENTIFIED BY '$pw'; FLUSH PRIVILEGES;" -Password ''
  $set = $set.Replace($pw, '********')
  if ($set -match 'ERROR') { Write-Host $set; throw 'setting the root password failed' }
  Write-Host 'root password set from .secrets/mysql_root_password.txt'
}

# Prove the outcome: passwordless must be refused, the stored password accepted.
$denied = Invoke-Mysql -Sql 'SELECT 1;'
$allowed = Invoke-Mysql -Sql 'SELECT CURRENT_USER() AS user, VERSION() AS version;' -Password $pw
Write-Host ("passwordless login: " + $(if ($denied -match 'ERROR 1045') { 'rejected (good)' } else { 'STILL ALLOWED' }))
Write-Host $allowed.Replace($pw, '********')
