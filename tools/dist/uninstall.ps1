# VBMP uninstaller. If UE4SS was installed by this package (marker file present) it removes
# dwmapi.dll and the whole ue4ss folder; otherwise it only removes the VBMP/VBTools mods.
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
if (-not $GameDir) { $GameDir = Read-Host 'Paste the VOID/BREAKER game folder' }
$bin = Join-Path $GameDir 'VOIDBREAKER\Binaries\Win64'
if (Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close the game first.' }
$ue = Join-Path $bin 'ue4ss'

if (Test-Path (Join-Path $ue 'VBMP_INSTALLED.txt')) {
    Remove-Item (Join-Path $bin 'dwmapi.dll') -Force -ErrorAction SilentlyContinue
    Remove-Item $ue -Recurse -Force
    "Removed UE4SS and VBMP from $bin"
} else {
    foreach ($m in 'VBMP', 'VBTools') {
        $dst = Join-Path $ue "Mods\$m"
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force; "removed mod $m" }
    }
    $txt = Join-Path $ue 'Mods\mods.txt'
    if (Test-Path $txt) {
        $t = (Get-Content $txt -Raw) -replace '(?m)^(VBMP|VBTools)\s*:\s*[01]\r?\n?', ''
        [IO.File]::WriteAllText($txt, $t)
    }
    'UE4SS was not installed by VBMP, so it was left in place.'
}
