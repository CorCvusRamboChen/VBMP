# Show VBMP lines (and errors) from the gaming PC's UE4SS.log.
param(
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519'),
    [int]$Tail = 60
)
$log = ssh -i $Key -o BatchMode=yes -n $GamingPc 'type C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64\ue4ss\UE4SS.log'
$hits = $log | Where-Object { $_ -match '\[VB\w*\]|Lua mod .VB|error|Error|failed|Failed|FAILED|exception' }
$hits | Select-Object -Last $Tail
"--- $($log.Count) log lines, $($hits.Count) matched ---"
