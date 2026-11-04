# Runs ON the gaming PC. Copies every VOID/BREAKER save location into
# %USERPROFILE%\vbmp\save-backups\<label>-<timestamp>\ and lists what was copied.
# Copy only - the originals are never touched.
param([string]$Label = 'manual')
$ErrorActionPreference = 'Stop'
$sources = @()
$local = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved\SaveGames'
if (Test-Path $local) { $sources += $local }
foreach ($ud in Get-ChildItem 'C:\D\userdata' -Directory -ErrorAction SilentlyContinue) {
    $cloud = Join-Path $ud.FullName '2615540'
    if (Test-Path $cloud) { $sources += $cloud }
}
if (-not $sources) { throw 'no save location found' }

$dest = Join-Path $env:USERPROFILE ("vbmp\save-backups\{0}-{1}" -f $Label, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($s in $sources) {
    $name = ($s -replace '^[A-Za-z]:\\', '') -replace '[\\:]', '_'
    Copy-Item $s (Join-Path $dest $name) -Recurse
}
"backup: $dest"
Get-ChildItem $dest -Recurse -File | ForEach-Object {
    "  {0,10}  {1:yyyy-MM-dd HH:mm:ss}  {2}" -f $_.Length, $_.LastWriteTime, $_.FullName.Substring($dest.Length)
}
