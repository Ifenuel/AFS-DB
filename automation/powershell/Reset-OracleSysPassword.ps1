# Regenerate the Oracle SYSDBA password file (break-glass access).
#
# Why: this host has no ORA_DBA membership for the interactive user and no known
# SYS password, so password-file authentication is the only supported route to
# SYSDBA. orapwd rewrites PWDFREE.ora with a new SYS password; the previous file
# is backed up first. Nothing else about the database is touched.
#
# Requires administrator rights because the Oracle password file is ACL-locked
# to the service account. Run once, then connect with the password written to
# .secrets/oracle_sys_password.txt.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OracleHome = 'C:\app\oraclelab\product\26ai\dbhomeFree',
  [string]$OutDir     = (Join-Path (Get-Location) '.secrets')
)

$ErrorActionPreference = 'Stop'
$pwfile = Join-Path $OracleHome 'database\PWDFREE.ora'
$orapwd = Join-Path $OracleHome 'bin\orapwd.exe'

if (-not (Test-Path -LiteralPath $orapwd)) { throw "orapwd not found at $orapwd" }
if (-not (Test-Path -LiteralPath $pwfile)) { throw "password file not found at $pwfile" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stamp  = Get-Date -Format 'yyyyMMddTHHmmss'
$backup = Join-Path $OutDir "PWDFREE.ora.backup-$stamp"
Copy-Item -LiteralPath $pwfile -Destination $backup -Force
Write-Host "backed up existing password file -> $backup"

# Oracle enforces complexity: upper, lower, digit and a special character.
# The specials are limited to characters that survive PowerShell, bash and
# SQL*Plus quoting (no @, no quotes, no backslash).
$upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
$lower   = 'abcdefghijkmnopqrstuvwxyz'
$digits  = '23456789'
$special = '#%+-_!*'
$all     = $upper + $lower + $digits + $special
function Pick([string]$set) {
  $b = New-Object byte[] 1
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return $set[$b[0] % $set.Length]
}
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$password = (Pick $upper) + (Pick $lower) + (Pick $digits) + (Pick $special) +
            (-join ($bytes | ForEach-Object { $all[$_ % $all.Length] }))

& $orapwd file=$pwfile password=$password entries=10 force=y
if ($LASTEXITCODE -ne 0) { throw "orapwd failed with exit code $LASTEXITCODE" }

$pwout = Join-Path $OutDir 'oracle_sys_password.txt'
Set-Content -LiteralPath $pwout -Value $password -Encoding ASCII -NoNewline
Write-Host "new SYS password written to $pwout (not printed)"

# The instance service runs as the local 'oraclelab' account and must keep read access.
& icacls $pwfile /grant 'oraclelab:R' | Out-Null
& icacls $pwfile /grant "$env:USERDOMAIN\$env:USERNAME:R" | Out-Null
Write-Host "ACLs updated for oraclelab and $env:USERNAME"

Write-Host "done. test with: sqlplus sys/<password>@//127.0.0.1:1521/FREE as sysdba"
