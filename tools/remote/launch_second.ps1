# Runs ON the gaming PC. Dual-instance experiment: start a SECOND VOID/BREAKER process (windowed,
# 1280x720) in the user's desktop session, bypassing the Steam launcher via steam_appid.txt next
# to the shipping exe (a standard Steamworks development file; remove it with -Cleanup).
param([switch]$Cleanup)
$ErrorActionPreference = 'Stop'
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
$appid = Join-Path $bin 'steam_appid.txt'
if ($Cleanup) {
    if (Test-Path $appid) { Remove-Item $appid; 'removed steam_appid.txt' } else { 'nothing to clean' }
    return
}
if (-not (Test-Path $appid)) { Set-Content $appid '2615540' -Encoding ascii -NoNewline; 'created steam_appid.txt' }
$owner = (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner)
$user = "$($owner.Domain)\$($owner.User)"
$tn = 'VBMP_LaunchSecond'
$exe = Join-Path $bin 'VOIDBREAKER-Win64-Shipping.exe'
$action = '"' + $exe + '" -windowed -ResX=1280 -ResY=720'
schtasks /create /tn $tn /tr $action /sc once /st 23:59 /it /ru $user /f | Out-Null
schtasks /run /tn $tn
Start-Sleep -Seconds 5
schtasks /delete /tn $tn /f | Out-Null
"second instance requested"
