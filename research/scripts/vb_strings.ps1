# Read-only: search the shipping exe for marker strings (ASCII and UTF-16LE).
$exe = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64\VOIDBREAKER-Win64-Shipping.exe'
$bytes = [IO.File]::ReadAllBytes($exe)
$latin = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
$bytes = $null

function Show-Context($label, $idx, $len, $wide) {
    $start = [Math]::Max(0, $idx - 8)
    $take = if ($wide) { 160 } else { 80 }
    $s = $latin.Substring($start, [Math]::Min($take, $latin.Length - $start))
    if ($wide) { $s = $s -replace "`0", '' }
    $s = $s -replace '[^\x20-\x7E]', '.'
    "  [$label] @0x$($idx.ToString('X')): $s"
}

$terms = @(
    '++UE5+Release-', 'Release-5.', '5.4.', '5.5.', '5.6.',
    'IpNetDriver', 'SteamNetDriver', 'SteamSocketsNetDriver', 'OnlineSubsystemSteam', 'OnlineSubsystemNull',
    'GameNetDriver', 'NetDriverDefinitions', 'ReplicationGraph', 'Iris',
    'GeometryCollection', 'ChaosDestruction', 'FractureEngine', 'DynamicMesh', 'GeometryScript',
    'ProjectLima', 'Mutable', 'PCG'
)
foreach ($t in $terms) {
    $count = 0; $shown = 0
    foreach ($wide in $false, $true) {
        $needle = if ($wide) { ($t.ToCharArray() | ForEach-Object { "$_`0" }) -join '' } else { $t }
        $i = $latin.IndexOf($needle, [StringComparison]::Ordinal)
        while ($i -ge 0 -and $count -lt 2000) {
            $count++
            if ($shown -lt 2) { Show-Context $t $i $needle.Length $wide; $shown++ }
            $i = $latin.IndexOf($needle, $i + 1, [StringComparison]::Ordinal)
        }
    }
    "$t => $count hits"
}
