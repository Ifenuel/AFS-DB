# Run SQL*Plus as SYSDBA using the password stored in .secrets/oracle_sys_password.txt.
# The password is read from disk and passed through the environment, never printed
# and never placed on a command line that gets logged verbatim.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OracleHome = 'C:\app\oraclelab\product\26ai\dbhomeFree',
  [string]$Connect    = '//127.0.0.1:1521/FREE.FALSE',
  [string]$Query,
  [string]$File,
  [string]$OutFile,
  [string]$OracleSid = 'FREE',
  [switch]$Local
)
$ErrorActionPreference = 'Stop'
$sqlplus = Join-Path $OracleHome 'bin\sqlplus.exe'
$pwPath  = Join-Path (Get-Location) '.secrets\oracle_sys_password.txt'
if (-not (Test-Path -LiteralPath $pwPath)) { throw "missing $pwPath - run Reset-OracleSysPassword.ps1 first" }
$pw = (Get-Content -LiteralPath $pwPath -Raw).Trim()

# SQL*Plus cannot reliably open a path containing spaces, and this project path
# contains one, so the file's statements are inlined into the temp script.
# A local (bequeath) connection needs no listener, which is the only way to
# STARTUP a database that is currently down.
$conn = if ($Local) { 'sys/"' + $pw + '" as sysdba' } else { 'sys/"' + $pw + '"@' + $Connect + ' as sysdba' }
$env:ORACLE_SID = $OracleSid
$env:ORACLE_HOME = $OracleHome

$lines = @('SET DEFINE OFF', 'SET PAGESIZE 200', 'SET LINESIZE 200', 'SET FEEDBACK ON', 'SET HEADING ON')
if ($File) {
  if (-not (Test-Path -LiteralPath $File)) { throw "SQL file not found: $File" }
  $lines += (Get-Content -LiteralPath $File -Raw) -split "`r?`n"
}
if ($Query) { $lines += $Query }
$lines += 'EXIT'
$tmp = [System.IO.Path]::GetTempFileName() + '.sql'
Set-Content -LiteralPath $tmp -Value ("CONNECT $conn`n" + ($lines -join "`n")) -Encoding ASCII

try {
  $out = & $sqlplus -L -S /nolog "@$tmp" 2>&1 | Out-String
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
# Scrub any accidental echo of the password before it can reach a log file.
$out = $out.Replace($pw, '********')
if ($OutFile) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $OutFile -Value $out -Encoding UTF8
}
if ($out -match 'ORA-\d+') { Write-Host $out; exit 2 }
Write-Host $out
