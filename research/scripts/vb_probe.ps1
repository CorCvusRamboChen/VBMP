# Read-only probe of the VOID/BREAKER install. Prints facts, changes nothing.
$ErrorActionPreference = 'Continue'
$cands = @('C:\D\steamapps\common\VOIDBREAKER', 'F:\SteamLibrary\steamapps\common\VOIDBREAKER')
$root = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $root) {
    Write-Output 'GAME DIR NOT FOUND in candidates; searching steamapps\common folders:'
    foreach ($lib in 'C:\D\steamapps\common', 'F:\SteamLibrary\steamapps\common') {
        if (Test-Path $lib) { Get-ChildItem $lib -Directory | ForEach-Object { "  $lib\$($_.Name)" } }
    }
    exit
}
Write-Output "ROOT: $root"
Write-Output '== top level =='
Get-ChildItem $root | ForEach-Object { "  $($_.Name)" }

Write-Output '== app manifest =='
$steamapps = Split-Path (Split-Path $root)
Get-ChildItem $steamapps -Filter 'appmanifest_*.acf' | ForEach-Object {
    $t = Get-Content $_.FullName -Raw
    if ($t -match '"installdir"\s+"VOIDBREAKER"') {
        Write-Output "  file: $($_.Name)"
        foreach ($k in 'appid', 'name', 'buildid', 'LastUpdated', 'TargetBuildID', 'SizeOnDisk') {
            if ($t -match ('"' + $k + '"\s+"([^"]*)"')) { Write-Output "  $k = $($Matches[1])" }
        }
    }
}

Write-Output '== executables (version info) =='
Get-ChildItem $root -Recurse -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object {
    $v = $_.VersionInfo
    "  $($_.FullName.Substring($root.Length))  size=$([math]::Round($_.Length/1MB,1))MB  FileVer=$($v.FileVersion)  ProductVer=$($v.ProductVersion)  Product=$($v.ProductName)"
}

Write-Output '== anti-cheat / loader markers =='
$markers = 'EasyAntiCheat', 'BattlEye', 'EOSBootstrapper', 'ue4ss', 'UE4SS', 'dwmapi.dll', 'xinput1_3.dll', 'steam_api64.dll', 'EOSSDK-Win64-Shipping.dll'
foreach ($m in $markers) {
    $hits = Get-ChildItem $root -Recurse -Filter "*$m*" -ErrorAction SilentlyContinue
    foreach ($h in $hits) { "  $m -> $($h.FullName.Substring($root.Length))" }
}

Write-Output '== Binaries folders =='
Get-ChildItem $root -Recurse -Directory -Filter Win64 -ErrorAction SilentlyContinue | ForEach-Object {
    "  [$($_.FullName.Substring($root.Length))]"
    Get-ChildItem $_.FullName -File | ForEach-Object { "     $($_.Name)  $([math]::Round($_.Length/1MB,1))MB" }
}

Write-Output '== Paks =='
$paks = Get-ChildItem $root -Recurse -Include *.pak, *.utoc, *.ucas, *.sig -ErrorAction SilentlyContinue
foreach ($p in $paks) { "  $($p.FullName.Substring($root.Length))  $([math]::Round($p.Length/1MB,1))MB" }

Write-Output '== utoc headers (encryption flag) =='
foreach ($p in ($paks | Where-Object { $_.Extension -eq '.utoc' })) {
    $fs = [IO.File]::OpenRead($p.FullName)
    $b = New-Object byte[] 96
    [void]$fs.Read($b, 0, 96); $fs.Close()
    $magic = [Text.Encoding]::ASCII.GetString($b, 0, 16)
    $ver = $b[16]
    $guid = -join ($b[64..79] | ForEach-Object { $_.ToString('x2') })
    $flags = $b[80]
    $enc = ($flags -band 2) -ne 0
    "  $($p.Name): magic=$magic tocVersion=$ver flags=$flags encrypted=$enc keyGuid=$guid"
}

Write-Output '== pak footers (encryption flag) =='
foreach ($p in ($paks | Where-Object { $_.Extension -eq '.pak' })) {
    $fs = [IO.File]::OpenRead($p.FullName)
    $n = [Math]::Min(400, $fs.Length)
    [void]$fs.Seek(-$n, 'End')
    $b = New-Object byte[] $n
    [void]$fs.Read($b, 0, $n); $fs.Close()
    $found = $false
    for ($i = $n - 4; $i -ge 17; $i--) {
        if ($b[$i] -eq 0xE1 -and $b[$i+1] -eq 0x12 -and $b[$i+2] -eq 0x6F -and $b[$i+3] -eq 0x5A) {
            $ver = [BitConverter]::ToInt32($b, $i + 4)
            $encIdx = $b[$i - 1]
            $guid = -join ($b[($i-17)..($i-2)] | ForEach-Object { $_.ToString('x2') })
            "  $($p.Name): pakVersion=$ver encryptedIndex=$encIdx keyGuid=$guid"
            $found = $true; break
        }
    }
    if (-not $found) { "  $($p.Name): footer magic not found" }
}

Write-Output '== Engine/Plugins hint (folder names only) =='
foreach ($d in 'Engine\Plugins', 'Engine\Binaries\ThirdParty') {
    $full = Join-Path $root $d
    if (Test-Path $full) { Get-ChildItem $full -Directory -Recurse -Depth 1 | ForEach-Object { "  $($_.FullName.Substring($root.Length))" } }
}
