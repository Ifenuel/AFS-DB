# Register (and optionally trigger) the nightly MySQL logical backup.
# Mirror of Register-OracleBackupTask.ps1: same battery and catch-up settings, so
# a suspended laptop does not silently skip the night's backup.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$TaskName = 'AFS MySQL Backup',
  [string]$Time     = '02:30',
  [switch]$Run
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'automation\powershell\Invoke-MysqlBackup.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "backup script not found: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script) `
  -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description 'AFS-DBA-001: nightly mysqldump of afs_lab with 7-day retention.' | Out-Null

if ($Run) { Start-ScheduledTask -TaskName $TaskName }

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
  TaskName           = $task.TaskName
  State              = $task.State
  NextRunTime        = $info.NextRunTime
  LastRunTime        = $info.LastRunTime
  LastTaskResult     = $info.LastTaskResult
  AllowOnBatteries   = -not $task.Settings.DisallowStartIfOnBatteries
  StartWhenAvailable = $task.Settings.StartWhenAvailable
} | Format-List
