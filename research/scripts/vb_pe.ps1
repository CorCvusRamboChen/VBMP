# Read-only: list PE sections of the shipping exe (a `.bind` section means SteamStub DRM).
$exe = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64\VOIDBREAKER-Win64-Shipping.exe'
$fs = [IO.File]::OpenRead($exe)
$br = New-Object IO.BinaryReader($fs)
$fs.Seek(0x3C, 'Begin') | Out-Null
$pe = $br.ReadInt32()
$fs.Seek($pe + 6, 'Begin') | Out-Null
$nsec = $br.ReadUInt16()
$fs.Seek($pe + 20, 'Begin') | Out-Null
$optSize = $br.ReadUInt16()
$fs.Seek($pe + 24 + 16, 'Begin') | Out-Null
$entry = $br.ReadUInt32()
Write-Output ("entry point RVA = 0x{0:X}" -f $entry)
$fs.Seek($pe + 24 + $optSize, 'Begin') | Out-Null
for ($i = 0; $i -lt $nsec; $i++) {
    $name = [Text.Encoding]::ASCII.GetString($br.ReadBytes(8)).TrimEnd([char]0)
    $vsize = $br.ReadUInt32(); $va = $br.ReadUInt32(); $rsize = $br.ReadUInt32(); $rptr = $br.ReadUInt32()
    $br.ReadBytes(12) | Out-Null
    $ch = $br.ReadUInt32()
    $pos = $fs.Position
    # entropy of first 64 KB of the section
    $n = [Math]::Min(65536, $rsize)
    $ent = 0
    if ($n -gt 0) {
        $fs.Seek($rptr, 'Begin') | Out-Null
        $buf = $br.ReadBytes($n)
        $cnt = New-Object int[] 256
        foreach ($b in $buf) { $cnt[$b]++ }
        foreach ($c in $cnt) { if ($c -gt 0) { $p = $c / $n; $ent -= $p * [Math]::Log($p, 2) } }
    }
    $fs.Seek($pos, 'Begin') | Out-Null
    Write-Output ("{0,-8} VA=0x{1:X8} vsize={2,10} rawsize={3,10} flags=0x{4:X8} entropy64k={5:N2}" -f $name, $va, $vsize, $rsize, $ch, $ent)
}
$fs.Close()
