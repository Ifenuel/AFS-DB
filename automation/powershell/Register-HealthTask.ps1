# Register (and optionally trigger) the hourly AFS backup health monitor.
# The monitor writes its findings to C:\ProgramData\AFS\logs\backup_health.log and
# returns 0/1/2, so it can be wired to any pager later without changing the check.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$TaskName = 'AFS Backup Health',
  [switch]$Run
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $repo 'automation\powershell\Test-AfsBackupHealth.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "health script not found: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script) `
  -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
  -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description 'AFS-DBA-001: hourly check of backup completeness, FRA usage and dump age.' | Out-Null

if ($Run) { Start-ScheduledTask -TaskName $TaskName }

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
  TaskName        = $task.TaskName
  State           = $task.State
  NextRunTime     = $info.NextRunTime
  LastRunTime     = $info.LastRunTime
  LastTaskResult  = $info.LastTaskResult
} | Format-List
