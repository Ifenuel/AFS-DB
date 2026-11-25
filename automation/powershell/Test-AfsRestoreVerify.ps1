# RESTORE VERIFYONLY WITH CHECKSUM over the newest full backup of each AFS database.
# Reading the msdb history proves a backup was taken; VERIFYONLY proves the media
# can still be read and the backup set is complete. It does not prove the data is
# logically consistent - only a restore drill does that.
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Server = '.'
)
$ErrorActionPreference = 'Stop'
$cs = "Server=$Server;Database=master;Integrated Security=true;Connect Timeout=20;Encrypt=false;Application Name=AFS-RestoreVerify"
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()

function Invoke-Sql {
  param([string]$Sql)
  $cmd = $conn.CreateCommand()
  $cmd.CommandTimeout = 300
  $cmd.CommandText = $Sql
  $cmd.ExecuteNonQuery() | Out-Null
}

$find = @"
SELECT d.name,
       (SELECT TOP 1 b.physical_device_name
          FROM msdb.dbo.backupset s
          JOIN msdb.dbo.backupmediafamily b ON b.media_set_id = s.media_set_id
         WHERE s.database_name = d.name AND s.type IN ('D','F')
         ORDER BY s.backup_finish_date DESC) AS backup_file
FROM sys.databases d
WHERE d.name LIKE 'AFS[_]%' AND d.name NOT LIKE '%RestoreTest%'
ORDER BY d.name;
"@
$cmd = $conn.CreateCommand()
$cmd.CommandText = $find
$r = $cmd.ExecuteReader()
$targets = @()
while ($r.Read()) { $targets += [pscustomobject]@{ Database = $r.GetString(0); File = $(if ($r.IsDBNull(1)) { $null } else { $r.GetString(1) }) } }
$r.Close()

$fail = 0
$rows = @()
foreach ($t in $targets) {
  if (-not $t.File) { $rows += [pscustomobject]@{ Database = $t.Database; Status = 'NO BACKUP'; Detail = 'no full backup in msdb' }; $fail++; continue }
  if (-not (Test-Path -LiteralPath $t.File)) { $rows += [pscustomobject]@{ Database = $t.Database; Status = 'MISSING FILE'; Detail = $t.File }; $fail++; continue }
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Sql ("RESTORE VERIFYONLY FROM DISK = N'{0}' WITH CHECKSUM;" -f $t.File.Replace("'", "''"))
    $sw.Stop()
    $mb = [math]::Round((Get-Item -LiteralPath $t.File).Length / 1MB, 1)
    $rows += [pscustomobject]@{ Database = $t.Database; Status = 'VERIFIED'; Detail = ("{0} MB, {1} ms, {2}" -f $mb, $sw.ElapsedMilliseconds, (Split-Path -Leaf $t.File)) }
  } catch {
    $rows += [pscustomobject]@{ Database = $t.Database; Status = 'FAILED'; Detail = $_.Exception.Message }
    $fail++
  }
}
$conn.Close()

$rows | Format-Table -AutoSize
if ($fail -gt 0) { Write-Host "$fail of $($rows.Count) databases did not verify"; exit 1 }
Write-Host "all $($rows.Count) databases verified"
exit 0
