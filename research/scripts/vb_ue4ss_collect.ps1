# Copy UE4SS outputs (log, dumps, headers, usmap) out of the game folder into
# %USERPROFILE%\vbmp\dumps\<buildid>-<timestamp>\. Read-only for the game folder.
$ErrorActionPreference = 'Stop'
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
$acf = Get-Content 'C:\D\steamapps\appmanifest_2615540.acf' -Raw
$build = if ($acf -match '"buildid"\s+"(\d+)"') { $Matches[1] } else { 'unknown' }
$dest = Join-Path $env:USERPROFILE ("vbmp\dumps\{0}-{1}" -f $build, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $dest | Out-Null
$items = Get-ChildItem $bin, (Join-Path $bin 'ue4ss') -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(UE4SS\.log|UE4SS_ObjectDump\.txt|.*\.usmap|CXXHeaderDump|UHTHeaderDump|UE4SS_SDK|VBMPDump_stage\d\.done|.*\.dmp)$' }
foreach ($i in $items) { Copy-Item $i.FullName $dest -Recurse -Force }
Write-Output "collected into $dest"
Get-ChildItem $dest | ForEach-Object {
    $size = if ($_.PSIsContainer) { (Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum } else { $_.Length }
    "  {0,-32} {1,12}" -f $_.Name, $size
}
