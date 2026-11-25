# Register (and optionally trigger) the daily Oracle RMAN backup in Task Scheduler.
# The task runs a wrapper .cmd that calls Invoke-OracleRman.ps1 from the repository
# root, because that helper reads the SYS password from .secrets.
#
# Settings that matter on a laptop: the backup starts even on battery and catches
# up after a missed start (StartWhenAvailable), so a suspended machine does not
# silently skip the night's backup. The task runs only while the user is logged
# on, because the credentials file is protected by that user's profile.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$TaskName = 'AFS Oracle RMAN Backup',
  [string]$Time     = '02:00',
  [string]$Wrapper  = 'C:\ProgramData\AFS\bin\oracle_rman_backup.cmd',
  [switch]$Run
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Wrapper)) { throw "wrapper not found: $Wrapper" }

$action = New-ScheduledTaskAction -Execute $Wrapper `
  -WorkingDirectory (Split-Path -Parent $Wrapper)
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal -Force `
  -Description 'AFS-DBA-001: daily Oracle RMAN full backup plus archived logs, retention 2 days.' | Out-Null

if ($Run) { Start-ScheduledTask -TaskName $TaskName }

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
[pscustomobject]@{
  TaskName          = $task.TaskName
  State             = $task.State
  NextRunTime       = $info.NextRunTime
  LastRunTime       = $info.LastRunTime
  LastTaskResult    = $info.LastTaskResult
  AllowOnBatteries  = $task.Settings.DisallowStartIfOnBatteries -eq $false
  StartWhenAvailable = $task.Settings.StartWhenAvailable
  LogonType         = $task.Principal.LogonType
} | Format-List
