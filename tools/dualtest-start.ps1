# Dual-instance test bootstrap: snapshot the save, start instance A (Steam) and instance B
# (second process, windowed) on the gaming PC, press Continue in both (never New Game) and wait
# until both have a player. Restore afterwards with:
#   ssh ... save_slots.ps1 -Action restore -Name <slot>;  launch_second.ps1 -Cleanup
param(
    [string]$SaveSlot = ('dual-' + (Get-Date -Format 'MMdd-HHmm')),
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$ssh = @('-i', $Key, '-o', 'BatchMode=yes')
$dev = Join-Path $PSScriptRoot 'dev.ps1'
$continue = 'local w = find("WBP_PlayMenu_C"); w["BndEvt__WBP_PlayMenu_BTN_Continue_K2Node_ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"](w, w.BTN_Continue); out("continue")'

ssh @ssh -n $GamingPc ('powershell -NoProfile -ExecutionPolicy Bypass -File vbmp\scripts\save_slots.ps1 -Action save -Name ' + $SaveSlot)
ssh @ssh -n $GamingPc 'taskkill /F /IM VOIDBREAKER-Win64-Shipping.exe >nul 2>&1 & taskkill /F /IM VOIDBREAKER.exe >nul 2>&1 & del "%LOCALAPPDATA%\VOIDBREAKER\Saved\VBMP_slots.txt" >nul 2>&1 & exit 0' | Out-Null
Start-Sleep -Seconds 5

& (Join-Path $PSScriptRoot 'selftest-start.ps1') | Select-Object -Last 1
ssh @ssh -n $GamingPc 'powershell -NoProfile -ExecutionPolicy Bypass -File vbmp\scripts\launch_second.ps1' | Out-Null

'waiting for instance B main menu...'
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 6
    $r = & $dev -Slot B -Lua 'out(find("WBP_PlayMenu_C") ~= nil)' -TimeoutSec 5
    if ($r -match '^true') { break }
}
if ($r -notmatch '^true') { throw "instance B menu not reached: $r" }
& $dev -Slot B -Lua $continue | Out-Null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 6
    $r = & $dev -Slot B -Lua 'out(player() ~= nil, world())' -TimeoutSec 5
    if ($r -match '^true') { "B in game: $r"; "save slot: $SaveSlot"; return }
}
throw "instance B never got a player: $r"
