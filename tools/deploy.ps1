# Copy Lua mods from src\lua\ to the gaming PC and set which are enabled.
# Mods load at game start, so restart the game after deploying.
#   deploy.ps1 -Enable VBTools -Disable VBMP,VBMPDump
param(
    [string[]]$Enable = @('VBMP'),
    [string[]]$Disable = @('VBMPDump'),
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$ssh = @('-i', $Key, '-o', 'BatchMode=yes')
$remoteMods = 'C:/D/steamapps/common/VOIDBREAKER/VOIDBREAKER/Binaries/Win64/ue4ss/Mods'

$running = ssh @ssh -n $GamingPc 'tasklist /NH | findstr /I VOIDBREAKER-Win64'
if ($running -match 'VOIDBREAKER') { Write-Warning 'game is running: changes apply on next launch' }

ssh @ssh -n $GamingPc 'if not exist vbmp\scripts mkdir vbmp\scripts'
scp @ssh (Join-Path $root 'tools\remote\set_mod.ps1') "${GamingPc}:vbmp/scripts/"
$set = 'powershell -NoProfile -ExecutionPolicy Bypass -File vbmp\scripts\set_mod.ps1'
foreach ($m in $Enable) {
    scp @ssh -r (Join-Path $root "src\lua\$m") "${GamingPc}:$remoteMods/"
    ssh @ssh -n $GamingPc "$set -Name $m -On 1"
}
foreach ($m in $Disable) { ssh @ssh -n $GamingPc "$set -Name $m -On 0" }
