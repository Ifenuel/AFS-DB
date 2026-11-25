# Installs Oracle AI Database 26ai Free silently on Windows when the signed-in
# account name contains a space.
#
# The installer builds its Oracle home from the logon name (C:\app\<name>\product\26ai)
# and rejects spaces, so the install runs under a temporary local administrator whose
# name has none. The account is disabled once the database answers.
#
# Run from an elevated PowerShell session. The account password is read from
# C:\oracle\admin\lab_user_password.txt and never stored in this repository.

$ErrorActionPreference = 'Stop'

$LabUser   = 'oraclelab'
$PwFile    = 'C:\oracle\admin\lab_user_password.txt'
$CredFile  = 'C:\oracle\admin\oracle-lab-credentials.txt'
$MediaDir  = 'C:\oracle\media\free'
$Wrapper   = 'C:\oracle\media\install-oracle.cmd'
$DbService = 'OracleServiceFREE'

if (-not (Test-Path $PwFile)) {
    throw "Create $PwFile with the temporary account password first."
}
$LabPw = (Get-Content $PwFile -Raw).Trim()

# SYS password for the new database, taken from the local credentials file.
if (-not (Test-Path $CredFile)) {
    throw "Create $CredFile with the SYS password line first."
}
$DbPw = ((Get-Content $CredFile) | Where-Object { $_ -match 'password\s*:' } |
    Select-Object -First 1) -replace '^[^:]*:\s*', ''
if (-not $DbPw) { throw "No password line found in $CredFile." }

if (-not (Test-Path (Join-Path $MediaDir 'setup.exe'))) {
    throw "Installer media not found in $MediaDir."
}

# 1. Temporary local administrator with a space-free name.
if (-not (Get-LocalUser -Name $LabUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $LabUser -Password (ConvertTo-SecureString $LabPw -AsPlainText -Force) `
        -PasswordNeverExpires -AccountNeverExpires | Out-Null
}
Add-LocalGroupMember -Group 'Administrators' -Member $LabUser -ErrorAction SilentlyContinue

# 2. Silent install batch. /qn keeps it unattended; the log is the only progress signal.
@"
@echo off
cd /d $MediaDir
setup.exe /s /v"/qn PASSWORD=$DbPw LISTENER_PORT=1521 /l*v $MediaDir\install-system.log"
echo exit=%ERRORLEVEL% > $MediaDir\install-result.txt
schtasks /Delete /TN OracleFreeInstall /F >nul 2>&1
"@ | Set-Content -Path $Wrapper -Encoding ASCII

# 3. Run it as the temporary account with highest privileges.
schtasks /Create /TN OracleFreeInstall /TR "cmd /c $Wrapper" /SC ONCE /ST 23:59 `
    /RU $LabUser /RP $LabPw /RL HIGHEST /F | Out-Null
schtasks /Run /TN OracleFreeInstall | Out-Null

# 4. Wait for the service rather than for the installer window.
$deadline = (Get-Date).AddMinutes(30)
do {
    Start-Sleep -Seconds 30
    $svc = Get-Service -Name $DbService -ErrorAction SilentlyContinue
} while ((Get-Date) -lt $deadline -and (-not $svc -or $svc.Status -ne 'Running'))

if (-not $svc -or $svc.Status -ne 'Running') {
    throw "Install did not reach a running $DbService. Check $MediaDir\install-system.log."
}

# 5. Close the install account; the services run under their own virtual accounts.
icacls 'C:\app\oraclelab' /grant '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Disable-LocalUser -Name $LabUser

Write-Host "Oracle installed. Service $DbService is running."
Write-Host "Verify with: sqlplus sys/<password>@//127.0.0.1:1521/freepdb1 as sysdba"
