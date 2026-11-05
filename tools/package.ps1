# Build the player-facing package dist\VBMP-<version>.zip:
#   install.bat/.ps1, uninstall.bat/.ps1, README.txt
#   payload\Win64\dwmapi.dll + ue4ss\ (UE4SS experimental build, MIT) with VBMP + VBTools enabled
# UE4SS itself is copied once from the gaming PC's verified staging folder into
# research\_local\ue4ss-cache\ (see research/scripts/vb_get_ue4ss.ps1 for the SHA-256 check).
param(
    [string]$Version = '0.2.0',
    [string]$Ue4ssBuild = 'UE4SS_v3.0.1-1196-g236adf26',
    [string]$GamingPc = 'user@192.168.1.197',
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\id_ed25519')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$cache = Join-Path $root "research\_local\ue4ss-cache\$Ue4ssBuild"
if (-not (Test-Path (Join-Path $cache 'dwmapi.dll'))) {
    New-Item -ItemType Directory -Force (Split-Path $cache) | Out-Null
    scp -i $Key -o BatchMode=yes -r "${GamingPc}:vbmp/tools/$Ue4ssBuild/extracted" $cache
    if (-not (Test-Path (Join-Path $cache 'dwmapi.dll'))) { throw "UE4SS cache copy failed" }
}

$out = Join-Path $root "dist\VBMP-$Version"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$win64 = Join-Path $out 'payload\Win64'
New-Item -ItemType Directory -Force $win64 | Out-Null
Copy-Item (Join-Path $cache 'dwmapi.dll') $win64
Copy-Item (Join-Path $cache 'ue4ss') $win64 -Recurse
$ue = Join-Path $win64 'ue4ss'

# Settings: keep the log console visible for the test builds.
$ini = Join-Path $ue 'UE4SS-settings.ini'
$t = Get-Content $ini -Raw
$t = $t -replace '(?m)^ConsoleEnabled = 0', 'ConsoleEnabled = 1'
[IO.File]::WriteAllText($ini, $t)

foreach ($m in 'VBMP', 'VBTools') { Copy-Item (Join-Path $root "src\lua\$m") (Join-Path $ue 'Mods') -Recurse }
# The auto updater (VBMP\steam\vbmp-update.ps1) compares this with the latest GitHub release;
# development deploys (tools\deploy.ps1) have no version.txt and are never updated.
[IO.File]::WriteAllText((Join-Path $ue 'Mods\VBMP\version.txt'), $Version)
$mods = @(
    'CheatManagerEnablerMod : 1', 'ConsoleCommandsMod : 1', 'ConsoleEnablerMod : 1', 'SplitScreenMod : 0',
    'LineTraceMod : 0', 'BPML_GenericFunctions : 1', 'BPModLoaderMod : 1', 'VBMP : 1', 'VBTools : 1', '',
    '; Built-in keybinds, do not move up!', 'Keybinds : 1'
)
[IO.File]::WriteAllText((Join-Path $ue 'Mods\mods.txt'), ($mods -join "`r`n") + "`r`n")
$names = @('VBMP', 'VBTools', 'CheatManagerEnablerMod', 'ConsoleCommandsMod', 'ConsoleEnablerMod', 'SplitScreenMod', 'LineTraceMod', 'BPML_GenericFunctions', 'BPModLoaderMod', 'Keybinds')
$entries = $names | ForEach-Object {
    $on = if ($_ -in 'SplitScreenMod', 'LineTraceMod') { 'false' } else { 'true' }
    "    {`r`n        `"mod_name`": `"$_`",`r`n        `"mod_enabled`": $on`r`n    }"
}
[IO.File]::WriteAllText((Join-Path $ue 'Mods\mods.json'), "[`r`n" + ($entries -join ",`r`n") + "`r`n]")
"VBMP $Version, UE4SS $Ue4ssBuild" | Out-File (Join-Path $ue 'VBMP_INSTALLED.txt') -Encoding ascii

foreach ($f in 'install.ps1', 'install.bat', 'uninstall.ps1', 'uninstall.bat', 'README.txt',
        'vbmp-bridge.ps1', 'bridge-host.bat', 'bridge-join.bat', 'firewall-allow.bat') {
    Copy-Item (Join-Path $root "tools\dist\$f") $out
}

$zip = Join-Path $root "dist\VBMP-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
# Checksum file for the release (the updater refuses a download that does not match).
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$zip.sha256", "$hash  VBMP-$Version.zip`n")
"package: $zip ($size MB), sha256 $hash"
