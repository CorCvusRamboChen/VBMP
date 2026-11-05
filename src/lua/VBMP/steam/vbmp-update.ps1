# VBMP 自动更新：游戏启动时由 main.lua 在后台运行一次（看不见窗口）。
#
# 1. 读本机版本 Mods\VBMP\version.txt（打包时写入；开发时直接部署的没有这个文件 -> 不更新）
# 2. 问 GitHub 最新发布：https://api.github.com/repos/CorCvusRamboChen/VBMP/releases/latest
# 3. 更新的话，下载 VBMP-<版本>.zip 和 VBMP-<版本>.zip.sha256，校验 SHA-256，解压，
#    只替换 Mods\VBMP 和 Mods\VBTools（dwmapi.dll 运行中被占用，也基本不变）
# 4. 结果写进 Saved\VBMP_update_status.txt（state=uptodate / updated / error / dev），游戏里显示；
#    日志 Saved\VBMP_update.log
# 新文件在下次启动游戏时生效：UE4SS 的 Lua 在启动时加载，运行中换文件不影响当前这一局。
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'),
    [string]$Repo = 'CorCvusRamboChen/VBMP'
)
$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $Dir 'VBMP_update_status.txt'
$logPath = Join-Path $Dir 'VBMP_update.log'

function Log([string]$s) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $s
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 } catch { }
}
function Status([string]$state, [string]$current, [string]$latest, [string]$detail) {
    $t = "state=$state`ncurrent=$current`nlatest=$latest`ndetail=$detail`n"
    [IO.File]::WriteAllText($statusPath, $t, (New-Object Text.UTF8Encoding($false)))
}
function VersionKey([string]$v) {
    $parts = ($v.TrimStart('v') -split '[^0-9]+') | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    while ($parts.Count -lt 3) { $parts += 0 }
    return ('{0:D5}.{1:D5}.{2:D5}' -f $parts[0], $parts[1], $parts[2])
}

$modsDir = Split-Path (Split-Path $PSScriptRoot)          # ...\ue4ss\Mods
$versionFile = Join-Path $modsDir 'VBMP\version.txt'
$current = ''
try {
    if ((Get-Item $logPath -ErrorAction SilentlyContinue).Length -gt 512KB) { Remove-Item $logPath }
    if (-not (Test-Path $versionFile)) { Status 'dev' '' '' '开发版，不自动更新'; return }
    $current = (Get-Content $versionFile -Raw).Trim()
    Log "---- check, installed $current"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'VBMP-updater'; 'Accept' = 'application/vnd.github+json' }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 20
    $latest = ([string]$rel.tag_name).TrimStart('v')
    Log "latest release $latest"
    if ((VersionKey $latest) -le (VersionKey $current)) { Status 'uptodate' $current $latest '已是最新'; return }

    $zipName = "VBMP-$latest.zip"
    $zipAsset = $rel.assets | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
    $shaAsset = $rel.assets | Where-Object { $_.name -eq "$zipName.sha256" } | Select-Object -First 1
    if (-not $zipAsset -or -not $shaAsset) { throw "release $latest has no $zipName / .sha256" }

    $tmp = Join-Path $env:TEMP ("vbmp-update-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zipPath = Join-Path $tmp $zipName
    Status 'downloading' $current $latest "正在下载 $latest"
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = 'VBMP-updater' } -UseBasicParsing -TimeoutSec 300
    $want = ((Invoke-WebRequest -Uri $shaAsset.browser_download_url -Headers @{ 'User-Agent' = 'VBMP-updater' } -UseBasicParsing -TimeoutSec 60).Content |
        ForEach-Object { if ($_ -is [byte[]]) { [Text.Encoding]::ASCII.GetString($_) } else { $_ } }).Trim().Split(' ')[0].ToLower()
    $have = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw "SHA-256 mismatch: expected $want, got $have" }
    Log "downloaded $zipName, sha256 ok"

    $ex = Join-Path $tmp 'x'
    Expand-Archive -Path $zipPath -DestinationPath $ex -Force
    $newMods = Join-Path $ex 'payload\Win64\ue4ss\Mods'
    foreach ($m in 'VBMP', 'VBTools') {
        $src = Join-Path $newMods $m
        if (-not (Test-Path $src)) { throw "package has no Mods\$m" }
        Copy-Item -Path (Join-Path $src '*') -Destination (Join-Path $modsDir $m) -Recurse -Force
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Log "updated $current -> $latest"
    Status 'updated' $current $latest "已更新到 $latest，重启游戏生效"
}
catch {
    Log ("error: " + $_.Exception.Message)
    Status 'error' $current '' ("检查更新失败：" + $_.Exception.Message)
}
