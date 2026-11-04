# Install the staged UE4SS build + VBMPDump mod next to the shipping exe.
# Adds files only (dwmapi.dll, ue4ss\); no game file is modified. Undo: vb_ue4ss_uninstall.ps1.
param(
    [string]$Staged = (Join-Path $env:USERPROFILE 'vbmp\tools\UE4SS_v3.0.1-1196-g236adf26\extracted'),
    [string]$ModSource = (Join-Path $env:USERPROFILE 'vbmp\VBMPDump')
)
$ErrorActionPreference = 'Stop'
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
if (-not (Test-Path (Join-Path $bin 'VOIDBREAKER-Win64-Shipping.exe'))) { throw "shipping exe not found in $bin" }
foreach ($p in 'dwmapi.dll', 'ue4ss') {
    if (Test-Path (Join-Path $bin $p)) { throw "$p already exists in $bin; uninstall first" }
}
if (Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'game is running; close it first' }

Copy-Item (Join-Path $Staged 'dwmapi.dll') $bin
Copy-Item (Join-Path $Staged 'ue4ss') $bin -Recurse
$ue = Join-Path $bin 'ue4ss'

# Settings: show the log console and the GUI console (hidden until Ctrl+O).
$ini = Join-Path $ue 'UE4SS-settings.ini'
$t = Get-Content $ini -Raw
$t = $t -replace '(?m)^ConsoleEnabled = 0', 'ConsoleEnabled = 1'
$t = $t -replace '(?m)^GuiConsoleEnabled = 0', 'GuiConsoleEnabled = 1'
[IO.File]::WriteAllText($ini, $t)

# Mod files + enable in both mod lists.
Copy-Item $ModSource (Join-Path $ue 'Mods\VBMPDump') -Recurse
$txt = Join-Path $ue 'Mods\mods.txt'
$m = Get-Content $txt -Raw
$m = $m -replace '(?m)^; Built-in keybinds', "VBMPDump : 1`r`n`r`n; Built-in keybinds"
[IO.File]::WriteAllText($txt, $m)
# Text insert: PowerShell 5.1's ConvertFrom-Json wraps top-level arrays and corrupts the file.
$jsonPath = Join-Path $ue 'Mods\mods.json'
$j = Get-Content $jsonPath -Raw
$entry = "[`r`n    {`r`n        `"mod_name`": `"VBMPDump`",`r`n        `"mod_enabled`": true`r`n    },"
$j = ([regex]'^\s*\[').Replace($j, $entry, 1)
[IO.File]::WriteAllText($jsonPath, $j)

Write-Output "installed into $bin"
Get-ChildItem $bin | ForEach-Object { "  $($_.Name)" }
Select-String -Path $ini -Pattern '^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible) ' | ForEach-Object { "  ini: $($_.Line)" }
Select-String -Path $txt -Pattern 'VBMPDump' | ForEach-Object { "  mods.txt: $($_.Line)" }
