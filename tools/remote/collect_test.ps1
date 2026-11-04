# Runs ON the gaming PC. Gather everything a test session produced into one archive:
# %USERPROFILE%\vbmp\test-results\<timestamp>.tgz (path printed on the last line).
$ErrorActionPreference = 'Stop'
$saved = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $env:USERPROFILE "vbmp\test-results\$stamp"
New-Item -ItemType Directory -Force $dest | Out-Null

$files = @(
    (Join-Path $saved 'VB_mods.log'),
    (Join-Path $saved 'VBTrace_events.log'),
    (Join-Path $saved 'VBTrace_recording.lua'),
    (Join-Path $saved 'VBTools_fusion.txt'),
    (Join-Path $bin 'ue4ss\UE4SS.log')
)
foreach ($f in $files) { if (Test-Path $f) { Copy-Item $f $dest } }
Get-ChildItem $bin, (Join-Path $bin 'ue4ss') -Filter *.dmp -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-1) } | ForEach-Object { Copy-Item $_.FullName $dest }
& (Join-Path $PSScriptRoot 'save_slots.ps1') -Action list | Out-File (Join-Path $dest 'save-slots.txt') -Encoding utf8
$acf = Get-Content 'C:\D\steamapps\appmanifest_2615540.acf' -Raw
if ($acf -match '"buildid"\s+"(\d+)"') { "buildid $($Matches[1])" | Out-File (Join-Path $dest 'build.txt') -Encoding ascii }

Get-ChildItem $dest | ForEach-Object { "  {0,-28} {1,10}" -f $_.Name, $_.Length }
$tgz = Join-Path $env:USERPROFILE "vbmp\test-results\$stamp.tgz"
tar -czf $tgz -C (Split-Path $dest) $stamp
"ARCHIVE $tgz"
