# Read-only ADO.NET helper for AFS verification (no writes)
#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Server,
  [string]$Database = 'master',
  [Parameter(Mandatory)][string]$Query
)
$ErrorActionPreference = 'Stop'
$cs = "Server=$Server;Database=$Database;Integrated Security=true;Connect Timeout=20;Encrypt=false;Application Name=AFS-ReadOnly-Verify"
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
$conn.Open()
try {
  $cmd = $conn.CreateCommand()
  $cmd.CommandTimeout = 60
  $cmd.CommandText = $Query
  $r = $cmd.ExecuteReader()
  do {
    if ($r.FieldCount -gt 0) {
      $h = @()
      for ($i=0; $i -lt $r.FieldCount; $i++) { $h += [string]$r.GetName($i) }
      Write-Host ($h -join '|')
      while ($r.Read()) {
        $v = @()
        for ($i=0; $i -lt $r.FieldCount; $i++) {
          $x = $r.GetValue($i)
          if ($x -eq [DBNull]::Value) { $v += 'NULL' } else { $v += [string]$x }
        }
        Write-Host ($v -join '|')
      }
    }
  } while ($r.NextResult())
  $r.Close()
} finally {
  if ($conn.State -eq 'Open') { $conn.Close() }
  $conn.Dispose()
}
