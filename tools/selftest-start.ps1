# Self-test bootstrap on the gaming PC: (optionally) stop the game, deploy the mods, start the
# game in the user's desktop session, wait for the main menu, press Continue (never New Game)
# and wait until the player exists. Only for self-tests the user has agreed to; their save is
# protected by save slots (docs/test-plan.md).
param(
    [switch]$KillRunning,
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$ssh = @('-i', $Key, '-o', 'BatchMode=yes')
$dev = Join-Path $PSScriptRoot 'dev.ps1'

$running = ssh @ssh -n $GamingPc 'tasklist /NH | findstr /I VOIDBREAKER-Win64 & exit 0'
if ($running -match 'VOIDBREAKER') {
    if (-not $KillRunning) { throw 'game is running; pass -KillRunning to restart it' }
    ssh @ssh -n $GamingPc 'taskkill /F /IM VOIDBREAKER-Win64-Shipping.exe & taskkill /F /IM VOIDBREAKER.exe' | Out-Null
    Start-Sleep -Seconds 5
}
& (Join-Path $PSScriptRoot 'deploy.ps1') -Enable VBDev, VBMP, VBTools, VBTrace -Disable VBMPDump | Out-Null
ssh @ssh -n $GamingPc 'del "%LOCALAPPDATA%\VOIDBREAKER\Saved\VBDev_out.txt" 2>nul & powershell -NoProfile -ExecutionPolicy Bypass -File vbmp\scripts\launch_game.ps1' | Out-Null

'waiting for the main menu...'
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    $r = & $dev -Lua 'out(find("WBP_PlayMenu_C") ~= nil)' -TimeoutSec 4
    if ($r -match '^true') { break }
}
if ($r -notmatch '^true') { throw "main menu not reached: $r" }

'pressing Continue...'
& $dev -Lua 'local w = find("WBP_PlayMenu_C"); w["BndEvt__WBP_PlayMenu_BTN_Continue_K2Node_ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"](w, w.BTN_Continue); out("continue")' | Out-Null
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    $r = & $dev -Lua 'local p = player(); out(p ~= nil, world())' -TimeoutSec 4
    if ($r -match '^true') { "in game: $r"; return }
}
throw "player never appeared: $r"
