# Runs ON the gaming PC before a test session: back up the save and move old VB logs aside so
# the session's results start clean.
$ErrorActionPreference = 'Stop'
$saved = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'
& (Join-Path $PSScriptRoot 'save_backup.ps1') -Label 'pre-test' | Select-Object -First 1
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($n in 'VB_mods.log', 'VBTrace_events.log') {
    $f = Join-Path $saved $n
    if (Test-Path $f) {
        Rename-Item $f "$n.$stamp.old"
        "rotated $n"
    }
}
$running = [bool](Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue)
"game running: $running"
