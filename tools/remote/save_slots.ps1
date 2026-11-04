# Runs ON the gaming PC. Named save slots for VOID/BREAKER's single save file.
#   save_slots.ps1 -Action save -Name normal-run      copy the current save into a slot
#   save_slots.ps1 -Action list
#   save_slots.ps1 -Action restore -Name normal-run   put a slot back (game must be closed;
#                                                     the current save is backed up first)
#   save_slots.ps1                                    interactive menu (used by VBSaves.bat)
# The whole LimaSaveGame.sav is swapped: run progress AND out-of-run progression both come
# from the slot. Settings.sav is never touched.
param(
    [ValidateSet('save', 'list', 'restore', 'menu')][string]$Action = 'menu',
    [string]$Name
)
$ErrorActionPreference = 'Stop'
$saveDir = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved\SaveGames'
$saveFile = Join-Path $saveDir 'LimaSaveGame.sav'
$slotRoot = Join-Path $env:USERPROFILE 'vbmp\save-slots'
New-Item -ItemType Directory -Force $slotRoot | Out-Null

function Test-GameRunning {
    [bool](Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue)
}

function Save-Slot([string]$n) {
    if (-not (Test-Path $saveFile)) { throw "no save file at $saveFile" }
    $n = $n -replace '[^\w\-]', '_'
    $dir = Join-Path $slotRoot $n
    if (Test-Path $dir) {
        $old = "$dir.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item $dir $old
        "previous slot '$n' kept as $(Split-Path $old -Leaf)"
    }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $saveFile $dir
    $src = Get-Item $saveFile
    "saved slot '$n' (save written $($src.LastWriteTime), $($src.Length) bytes)"
    if (Test-GameRunning) { 'note: game is running - this is the last save the game wrote to disk' }
}

function Get-Slots {
    Get-ChildItem $slotRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'LimaSaveGame.sav') } |
        ForEach-Object {
            $f = Get-Item (Join-Path $_.FullName 'LimaSaveGame.sav')
            [pscustomobject]@{ Name = $_.Name; SaveTime = $f.LastWriteTime; Bytes = $f.Length }
        } | Sort-Object SaveTime -Descending
}

function Restore-Slot([string]$n) {
    if (Test-GameRunning) { throw 'close the game first (it would overwrite the restored save on exit)' }
    $src = Join-Path $slotRoot "$n\LimaSaveGame.sav"
    if (-not (Test-Path $src)) { throw "slot '$n' not found" }
    & (Join-Path $PSScriptRoot 'save_backup.ps1') -Label "before-restore-$n" | Select-Object -First 1
    Copy-Item $src $saveFile -Force
    # Make the restored file the newest so Steam Cloud treats the local copy as current.
    (Get-Item $saveFile).LastWriteTime = Get-Date
    "restored slot '$n'. If Steam shows a cloud conflict on launch, choose the LOCAL save."
}

switch ($Action) {
    'save' { if (-not $Name) { throw '-Name required' }; Save-Slot $Name }
    'list' { Get-Slots | Format-Table -AutoSize | Out-String }
    'restore' { if (-not $Name) { throw '-Name required' }; Restore-Slot $Name }
    'menu' {
        while ($true) {
            ''
            '=== VOID/BREAKER save slots ==='
            Get-Slots | Format-Table -AutoSize | Out-String
            '1) save current game into a slot'
            '2) restore a slot (game must be closed)'
            '3) quit'
            $c = Read-Host 'choose'
            try {
                if ($c -eq '1') { Save-Slot (Read-Host 'slot name (e.g. normal-boss)') }
                elseif ($c -eq '2') { Restore-Slot (Read-Host 'slot name to restore') }
                elseif ($c -eq '3') { break }
            } catch { "ERROR: $($_.Exception.Message)" }
        }
    }
}
