# Runs ON the gaming PC. Enable/disable a UE4SS mod in both mods.txt and mods.json.
# PowerShell 5.1's ConvertFrom-Json mangles top-level arrays, so both files are edited as text.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][ValidateSet('0', '1')][string]$On
)
$ErrorActionPreference = 'Stop'
$mods = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64\ue4ss\Mods'

$txtPath = Join-Path $mods 'mods.txt'
$txt = Get-Content $txtPath -Raw
$line = "$Name : $On"
if ($txt -match "(?m)^$([regex]::Escape($Name))\s*:\s*[01]") {
    $txt = $txt -replace "(?m)^$([regex]::Escape($Name))\s*:\s*[01]", $line
} else {
    $txt = $txt -replace '(?m)^; Built-in keybinds', "$line`r`n`r`n; Built-in keybinds"
}
[IO.File]::WriteAllText($txtPath, $txt)

$jsonPath = Join-Path $mods 'mods.json'
$json = Get-Content $jsonPath -Raw
$flag = if ($On -eq '1') { 'true' } else { 'false' }
$pattern = '("mod_name":\s*"' + [regex]::Escape($Name) + '",\s*"mod_enabled":\s*)(true|false)'
if ($json -match $pattern) {
    $json = [regex]::Replace($json, $pattern, ('${1}' + $flag))
} else {
    $entry = "[`r`n    {`r`n        `"mod_name`": `"$Name`",`r`n        `"mod_enabled`": $flag`r`n    },"
    $json = ([regex]'^\s*\[').Replace($json, $entry, 1)
}
[IO.File]::WriteAllText($jsonPath, $json)
$null = $json | ConvertFrom-Json   # throws if we broke it

"$Name -> $On"
