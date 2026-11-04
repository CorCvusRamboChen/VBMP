# Pull a test session's results from the gaming PC into research\_local\tests\<timestamp>\
# and print the VB mod log highlights. See docs/test-plan.md.
param(
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$ssh = @('-i', $Key, '-o', 'BatchMode=yes')

scp @ssh (Join-Path $root 'tools\remote\collect_test.ps1') (Join-Path $root 'tools\remote\save_slots.ps1') "${GamingPc}:vbmp/scripts/"
$out = ssh @ssh -n $GamingPc 'powershell -NoProfile -ExecutionPolicy Bypass -File vbmp\scripts\collect_test.ps1'
$out | Where-Object { $_ -notmatch '^ARCHIVE ' }
$remote = ($out | Where-Object { $_ -match '^ARCHIVE ' }) -replace '^ARCHIVE ', ''
if (-not $remote) { throw 'collector did not report an archive' }

$local = Join-Path $root 'research\_local\tests'
New-Item -ItemType Directory -Force $local | Out-Null
$name = Split-Path $remote -Leaf
scp @ssh "${GamingPc}:vbmp/test-results/$name" $local
tar -xzf (Join-Path $local $name) -C $local
Remove-Item (Join-Path $local $name)
$dir = Join-Path $local ($name -replace '\.tgz$', '')
"results in $dir"

$modsLog = Join-Path $dir 'VB_mods.log'
if (Test-Path $modsLog) {
    '--- VB_mods.log: errors / failures ---'
    Select-String -Path $modsLog -Pattern 'FAILED|error|MISSING|not found|cannot' | Select-Object -Last 40 | ForEach-Object { $_.Line }
}
