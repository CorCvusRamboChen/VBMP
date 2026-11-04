# Runs ON the gaming PC. Latest crash artefacts: UE4SS minidumps, UE crash folders, log tail.
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
'--- minidumps ---'
Get-ChildItem $bin, (Join-Path $bin 'ue4ss') -Filter *.dmp -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 3 | ForEach-Object { "{0}  {1}  {2}" -f $_.LastWriteTime, $_.Length, $_.FullName }
'--- UE crash folders ---'
Get-ChildItem (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved\Crashes') -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 2 | ForEach-Object {
        "{0}  {1}" -f $_.LastWriteTime, $_.FullName
        $ctx = Join-Path $_.FullName 'CrashContext.runtime-xml'
        if (Test-Path $ctx) {
            $x = Get-Content $ctx -Raw
            foreach ($tag in 'ErrorMessage', 'CrashType') {
                if ($x -match "<$tag>([\s\S]*?)</$tag>") { "  ${tag}: " + ($Matches[1].Trim() -replace '\s+', ' ').Substring(0, [Math]::Min(400, $Matches[1].Trim().Length)) }
            }
            if ($x -match '<CallStack>([\s\S]*?)</CallStack>') { '  CallStack:'; ($Matches[1].Trim() -split "`n" | Select-Object -First 12) | ForEach-Object { '    ' + $_.Trim() } }
        }
    }
'--- UE4SS.log tail ---'
Get-Content (Join-Path $bin 'ue4ss\UE4SS.log') -Tail 6
