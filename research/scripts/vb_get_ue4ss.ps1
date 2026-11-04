# Download a pinned UE4SS experimental build into its own empty staging folder, verify SHA-256,
# extract. Does NOT touch the game directory (vb_ue4ss_install.ps1 does that).
param(
    [string]$Asset = 'UE4SS_v3.0.1-1196-g236adf26.zip',
    [string]$Sha256 = '75dc8b081d324fe0598a87b26e37d13a84d3648cbb1d08eb48c514376407a11b'
)
$ErrorActionPreference = 'Stop'
$name = [IO.Path]::GetFileNameWithoutExtension($Asset)
$dir = Join-Path $env:USERPROFILE "vbmp\tools\$name"
if (Test-Path $dir) { throw "$dir already exists; refusing to overwrite" }
New-Item -ItemType Directory -Force $dir | Out-Null
$zip = Join-Path $dir $Asset
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/$Asset" -OutFile $zip -UseBasicParsing
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($got -ne $Sha256) { Remove-Item $zip; throw "SHA-256 mismatch: $got" }
Write-Output "sha256 OK ($((Get-Item $zip).Length) bytes)"
$x = Join-Path $dir 'extracted'
Expand-Archive $zip -DestinationPath $x
Get-ChildItem $x -Recurse -File | ForEach-Object { "  $($_.FullName.Substring($x.Length))  $($_.Length)" }
