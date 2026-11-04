# Remove UE4SS from the game folder (exactly what vb_ue4ss_install.ps1 added, plus the
# dump outputs it produced). Run vb_ue4ss_collect.ps1 first if the dumps are still needed.
$ErrorActionPreference = 'Stop'
$bin = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Binaries\Win64'
if (Get-Process -Name 'VOIDBREAKER-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'game is running; close it first' }
$targets = Get-ChildItem $bin | Where-Object {
    $_.Name -match '^(dwmapi\.dll|ue4ss|UE4SS\.log|UE4SS_ObjectDump\.txt|.*\.usmap|CXXHeaderDump|UHTHeaderDump|UE4SS_SDK|VBMPDump_stage\d\.done)$'
}
foreach ($t in $targets) { Remove-Item $t.FullName -Recurse -Force; "removed $($t.Name)" }
'remaining in Win64:'
Get-ChildItem $bin | ForEach-Object { "  $($_.Name)" }
