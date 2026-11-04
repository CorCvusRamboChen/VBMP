# Download a pinned FModel release into its own empty folder, verify SHA-256, extract.
param(
    [string]$Tag = 'nov-2026',
    [string]$Sha256 = '209bef15402dd58010cdb6bad03a799471f2100d671f8d5a52c1e613549b7de1'
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:USERPROFILE "vbmp\tools\FModel-$Tag"
if (Test-Path $dir) { throw "$dir already exists; refusing to overwrite" }
New-Item -ItemType Directory -Force $dir | Out-Null
$zip = Join-Path $dir 'FModel.zip'
$url = "https://github.com/4sval/FModel/releases/download/$Tag/FModel.zip"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($got -ne $Sha256) { Remove-Item $zip; throw "SHA-256 mismatch: $got" }
Write-Output "sha256 OK ($((Get-Item $zip).Length) bytes)"
Expand-Archive $zip -DestinationPath $dir
Get-ChildItem $dir | ForEach-Object { "  $($_.Name)  $($_.Length)" }
$exe = Get-ChildItem $dir -Recurse -Filter FModel.exe | Select-Object -First 1
if ($exe) {
    $sig = Get-AuthenticodeSignature $exe.FullName
    "FModel.exe version=$($exe.VersionInfo.FileVersion) signature=$($sig.Status) signer=$($sig.SignerCertificate.Subject)"
}
'--- .NET desktop runtimes ---'
$dn = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dn) { & dotnet --list-runtimes } else { 'dotnet not on PATH' }
Get-ChildItem 'C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App' -ErrorAction SilentlyContinue | ForEach-Object { "  WindowsDesktop.App $($_.Name)" }
