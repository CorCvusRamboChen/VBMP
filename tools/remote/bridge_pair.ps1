# Runs ON the gaming PC. Bridge test with two game instances on this PC: instance A (host) uses
# Saved\, instance B (client) uses Saved\VBMP_B\ (main.lua, via "bridge"). Starts a host bridge
# and a client bridge (127.0.0.1) as detached processes so they outlive the ssh session; logs go
# to %USERPROFILE%\vbmp\bridge_host.log / bridge_client.log.
#   bridge_pair.ps1            start both
#   bridge_pair.ps1 -Stop      stop both
param([switch]$Stop, [int]$Port = 27777)
$script = Join-Path $env:USERPROFILE 'vbmp\scripts\vbmp-bridge.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*vbmp-bridge.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "stopped bridge $($_.ProcessId)" }
if ($Stop) { return }
$saved = Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'
$logs = Join-Path $env:USERPROFILE 'vbmp'
$runs = @(
    @{ args = "-Role host -Port $Port -Dir `"$saved`""; log = 'bridge_host.log' },
    @{ args = "-Role client -HostAddr 127.0.0.1 -Port $Port -Dir `"$saved\VBMP_B`""; log = 'bridge_client.log' }
)
foreach ($r in $runs) {
    $cmd = "cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" $($r.args) > `"$logs\$($r.log)`" 2>&1"
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    "started $($r.log) pid $($res.ProcessId) rc $($res.ReturnValue)"
    Start-Sleep -Seconds 3
}
