# Runs ON the gaming PC. Is the game alive and making progress? Prints CPU seconds twice,
# 3 s apart, plus the last lines of the VB mods log and VBDev output.
$p = Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue
if (-not $p) { 'game: not running'; exit }
$c1 = $p.TotalProcessorTime.TotalSeconds
Start-Sleep -Seconds 3
$p.Refresh()
$c2 = $p.TotalProcessorTime.TotalSeconds
"game: pid $($p.Id)  responding=$($p.Responding)  cpu +$([math]::Round($c2 - $c1, 2)) s in 3 s  mem $([math]::Round($p.WorkingSet64 / 1GB, 2)) GB"
$saved = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'
'--- VBDev_out (first 2 lines) ---'
Get-Content (Join-Path $saved 'VBDev_out.txt') -TotalCount 2 -ErrorAction SilentlyContinue
"cmd pending: $(Test-Path (Join-Path $saved 'VBDev_cmd.lua'))"
"now $(Get-Date -Format HH:mm:ss)"
foreach ($n in 'VBMP_status.txt', 'VB_mods.log', 'VBDev_out.txt') {
    $f = Join-Path $saved $n
    if (Test-Path $f) { "{0,-18} written {1:HH:mm:ss}" -f $n, (Get-Item $f).LastWriteTime }
}
'--- VBMP status ---'
Get-Content (Join-Path $saved 'VBMP_status.txt') -ErrorAction SilentlyContinue
