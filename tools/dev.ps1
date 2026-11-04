# Run Lua inside the running game on the gaming PC (needs the VBDev mod) and print the result.
#   dev.ps1 -Lua 'out(player():K2_GetActorLocation())'
#   dev.ps1 -File some.lua
#   dev.ps1 -Shot            take a screenshot and copy it to research\_local\shots\
param(
    [string]$Lua,
    [string]$File,
    [switch]$Shot,
    [ValidateSet('', 'A', 'B')][string]$Slot = '',   # dual-instance tests: which game process
    [int]$TimeoutSec = 20,
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$ssh = @('-i', $Key, '-o', 'BatchMode=yes')
$remoteSaved = 'C:/Users/User/AppData/Local/VOIDBREAKER/Saved'

function Invoke-Remote([string]$code) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path $env:TEMP "vbdev_$id.lua"
    [IO.File]::WriteAllText($tmp, "-- id: $id`n$code`n", (New-Object Text.UTF8Encoding($false)))
    $suffix = if ($Slot) { "_$Slot" } else { '' }
    scp @ssh $tmp "${GamingPc}:$remoteSaved/VBDev_cmd$suffix.lua" | Out-Null
    Remove-Item $tmp
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $out = ssh @ssh -n $GamingPc ('type "' + $remoteSaved.Replace('/', '\') + "\VBDev_out$suffix.txt" + '" 2>nul')
        if ($out -and ($out[0] -eq "-- id: $id") -and ($out -contains '-- end')) {
            return ($out | Select-Object -Skip 1 | Where-Object { $_ -ne '-- end' })
        }
    }
    "TIMEOUT: no answer in $TimeoutSec s (is the game running with VBDev enabled?)"
}

if ($Shot) {
    $before = ssh @ssh -n $GamingPc ('dir /b /s "' + $remoteSaved.Replace('/', '\') + '\Screenshots\*.png" 2>nul')
    Invoke-Remote 'screenshot() out("shot requested")'
    Start-Sleep -Seconds 3
    $after = ssh @ssh -n $GamingPc ('dir /b /s /o:d "' + $remoteSaved.Replace('/', '\') + '\Screenshots\*.png" 2>nul')
    $new = @($after | Where-Object { $_ -and ($before -notcontains $_) })
    if (-not $new) { 'no new screenshot found'; return }
    $src = $new[-1]
    $dst = Join-Path $root 'research\_local\shots'
    New-Item -ItemType Directory -Force $dst | Out-Null
    $name = (Get-Date -Format 'HHmmss') + '_' + (Split-Path $src -Leaf)
    scp @ssh ("${GamingPc}:" + $src.Replace('\', '/')) (Join-Path $dst $name) | Out-Null
    Join-Path $dst $name
    return
}

if ($File) { $Lua = Get-Content $File -Raw }
if (-not $Lua) { throw 'give -Lua, -File or -Shot' }
Invoke-Remote $Lua
