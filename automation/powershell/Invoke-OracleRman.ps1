# Run RMAN as SYSDBA using the stored password.
# Credentials go inside the command file (not the command line) because the
# generated password contains characters that shells and RMAN's argument parser
# treat specially. Output is scrubbed before it is printed or saved.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$OracleHome = 'C:\app\oraclelab\product\26ai\dbhomeFree',
  [string]$OracleSid  = 'FREE',
  [string]$Connect    = '//127.0.0.1:1521/FREE.FALSE',
  [string]$Commands,
  [string]$File,
  [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$rman   = Join-Path $OracleHome 'bin\rman.exe'
$pwPath = Join-Path (Get-Location) '.secrets\oracle_sys_password.txt'
if (-not (Test-Path -LiteralPath $pwPath)) { throw "missing $pwPath" }
$pw = (Get-Content -LiteralPath $pwPath -Raw).Trim()

$env:ORACLE_SID  = $OracleSid
$env:ORACLE_HOME = $OracleHome

if ($File) {
  if (-not (Test-Path -LiteralPath $File)) { throw "RMAN script not found: $File" }
  $body = Get-Content -LiteralPath $File -Raw
} else {
  $body = $Commands
}

# Space-free directory: RMAN will not open a cmdfile path containing spaces.
$tmpDir = 'C:\ProgramData\AFS\tmp'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$tmp = Join-Path $tmpDir ("rman_{0}.rman" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$script = "CONNECT TARGET sys/""$pw""@$Connect`n" + $body + "`nEXIT"
Set-Content -LiteralPath $tmp -Value $script -Encoding ASCII

try {
  $out = & $rman "cmdfile=$tmp" 2>&1 | Out-String
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$out = $out.Replace($pw, '********')
if ($OutFile) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $OutFile -Value $out -Encoding UTF8
}
Write-Host $out
if ($out -match 'RMAN-\d+|ORA-\d+') { exit 2 }
