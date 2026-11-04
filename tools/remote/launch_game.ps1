# Runs ON the gaming PC (over ssh). Starts Steam + VOID/BREAKER in the logged-on user's desktop
# session through a one-shot scheduled task (/IT), then deletes the task. Needed because
# anything started directly from ssh lands in invisible session 0 (and a session-0 steam.exe
# kicks the desktop Steam out - see Serena memory gaming-pc-desktop-cbajbfj).
$ErrorActionPreference = 'Stop'
$tn = 'VBMP_LaunchOnce'
# Over ssh USERDOMAIN does not resolve to the machine account, so take it from the desktop
# session's explorer.exe owner.
$owner = (Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner)
$user = "$($owner.Domain)\$($owner.User)"
$action = '"C:\D\steam.exe" -applaunch 2615540'
schtasks /create /tn $tn /tr $action /sc once /st 23:59 /it /ru $user /f | Out-Null
schtasks /run /tn $tn
Start-Sleep -Seconds 5
schtasks /delete /tn $tn /f | Out-Null
"task $tn run and deleted"
