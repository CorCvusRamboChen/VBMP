# VBMP installer: copies UE4SS + the VBMP/VBTools mods next to the VOID/BREAKER shipping exe.
# Only adds files (dwmapi.dll, ue4ss\); no game file is changed. Undo with uninstall.bat.
param([string]$GameDir)
$ErrorActionPreference = 'Stop'

function Find-Game {
    $libs = @()
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) {
                $libs += ($m.Matches[0].Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $g = Join-Path $lib 'steamapps\common\VOIDBREAKER'
        if (Test-Path (Join-Path $g 'VOIDBREAKER\Binaries\Win64\VOIDBREAKER-Win64-Shipping.exe')) { return $g }
    }
    return $null
}

if (-not $GameDir) { $GameDir = Find-Game }
if (-not $GameDir) { $GameDir = Read-Host 'VOID/BREAKER not found automatically. Paste the game folder (the one containing VOIDBREAKER.exe)' }
$bin = Join-Path $GameDir 'VOIDBREAKER\Binaries\Win64'
if (-not (Test-Path (Join-Path $bin 'VOIDBREAKER-Win64-Shipping.exe'))) { throw "not a VOID/BREAKER folder: $GameDir" }
if (Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close the game first.' }

$payload = Join-Path $PSScriptRoot 'payload\Win64'
$ue = Join-Path $bin 'ue4ss'
if (Test-Path $ue) {
    # UE4SS already there (ours or another mod's): only add/refresh our mods and enable them.
    foreach ($m in 'VBMP', 'VBTools') {
        $dst = Join-Path $ue "Mods\$m"
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Copy-Item (Join-Path $payload "ue4ss\Mods\$m") (Join-Path $ue 'Mods') -Recurse
        $txt = Join-Path $ue 'Mods\mods.txt'
        $t = Get-Content $txt -Raw
        if ($t -match "(?m)^$m\s*:") { $t = $t -replace "(?m)^$m\s*:\s*[01]", "$m : 1" }
        else { $t = $t -replace '(?m)^; Built-in keybinds', "$m : 1`r`n`r`n; Built-in keybinds" }
        [IO.File]::WriteAllText($txt, $t)
        $json = Join-Path $ue 'Mods\mods.json'
        if (Test-Path $json) {
            $j = Get-Content $json -Raw
            $pat = '("mod_name":\s*"' + $m + '",\s*"mod_enabled":\s*)(true|false)'
            if ($j -match $pat) { $j = [regex]::Replace($j, $pat, '${1}true') }
            else { $j = ([regex]'^\s*\[').Replace($j, "[`r`n    {`r`n        `"mod_name`": `"$m`",`r`n        `"mod_enabled`": true`r`n    },", 1) }
            [IO.File]::WriteAllText($json, $j)
        }
    }
    "Updated VBMP + VBTools in existing UE4SS at $ue"
} else {
    Copy-Item (Join-Path $payload 'dwmapi.dll') $bin
    Copy-Item (Join-Path $payload 'ue4ss') $bin -Recurse
    "Installed UE4SS + VBMP + VBTools into $bin"
}
'Start the game normally from Steam. A black UE4SS log window opens with it - that is expected.'
