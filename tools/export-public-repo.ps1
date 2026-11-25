# Build a clean, public copy of this project for GitHub.
#
# What it does:
#   * copies code, configuration and captured evidence to a separate folder,
#   * leaves every Markdown file behind except README.md (so docs stay on this computer),
#   * never copies .env, .secrets, AI tool state or screenshots,
#   * refuses to finish if anything sensitive or any stray .md slipped through.
#
# It does not push. You review the folder, then init and push from there yourself.
param(
    [string]$Destination = (Join-Path $HOME 'Documents\Apex-Financial-Services-Public')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$include = @('sql-server', 'oracle', 'mysql', 'automation', 'site', 'test-data', 'evidence')
$excludeDirs = @('.git', 'docs', '.secrets', '.cloud-attachments', 'node_modules', '__pycache__', 'logs')
$excludeFiles = @('.env', '.env.local', '.env.production', '*.secret', '*.secrets', '*.bak', '*.trn', '*.mdf', '*.ldf')

if (Test-Path $Destination) {
    Write-Host "Target exists: $Destination"
    $answer = Read-Host 'Delete and rebuild it? [y/N]'
    if ($answer -ne 'y') { Write-Host 'Stopped.'; return }
    Remove-Item -Recurse -Force $Destination
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

foreach ($dir in $include) {
    $from = Join-Path $root $dir
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $Destination $dir
    $rcArgs = @($from, $to, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XD') + $excludeDirs + @('/XF') + $excludeFiles + @('*.md', '*.png', '*.webp')
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $dir (exit $LASTEXITCODE)" }
}
# README is the only Markdown file the public copy carries.
Copy-Item (Join-Path $root 'README.md') (Join-Path $Destination 'README.md') -Force
if (Test-Path (Join-Path $root '.gitignore')) {
    Copy-Item (Join-Path $root '.gitignore') (Join-Path $Destination '.gitignore') -Force
}

# ---------------------------------------------------------------- checks
$strayMd = Get-ChildItem $Destination -Recurse -Filter *.md | Where-Object { $_.Name -ne 'README.md' }
$secrets = Get-ChildItem $Destination -Recurse -Force |
    Where-Object { $_.Name -match '^\.env' -or $_.Name -like '*.secrets' -or $_.FullName -match '\\\.secrets\\' }
$codeFiles = Get-ChildItem $Destination -Recurse -File -Include *.ps1, *.sql, *.py, *.js
$secretHits = $codeFiles | Select-String -Pattern 'Password\s*=\s*"[^"]{6,}"' -ErrorAction SilentlyContinue

if ($strayMd)  { Write-Host "FAIL: $($strayMd.Count) Markdown file(s) would be published:"; $strayMd | ForEach-Object { Write-Host "  $($_.FullName)" }; exit 1 }
if ($secrets)  { Write-Host "FAIL: secret file(s) present:"; $secrets | ForEach-Object { Write-Host "  $($_.FullName)" }; exit 1 }
if ($secretHits) { Write-Host "WARN: literal passwords found, review before pushing:"; $secretHits | ForEach-Object { Write-Host "  $($_.Path):$($_.LineNumber)" } }

$files = (Get-ChildItem $Destination -Recurse -File).Count
$sizeMb = [math]::Round(((Get-ChildItem $Destination -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ""
Write-Host "Public copy ready: $Destination"
Write-Host "  files        : $files"
Write-Host "  size         : $sizeMb MB"
Write-Host "  markdown     : README.md only"
Write-Host "  secrets/env  : none"
Write-Host ""
Write-Host "Next, from that folder (you run these, not the agent):"
Write-Host "  git init && git add -A && git commit -m `"Initial commit`""
Write-Host "  git remote add origin <your-repo-url> && git push -u origin main"
