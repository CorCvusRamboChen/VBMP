# VBMP 打包日志：主菜单面板的 [打包日志] 按钮在后台运行它。
# 把联机相关的日志复制到一个 zip，放在桌面上（VBMP-logs-<时间>.zip），然后在资源管理器里选中它，
# 方便发给开发者。结果写进 Saved\VBMP_logs_export.txt（ok=<zip 路径> 或 error=<原因>）。
# 内容：UE4SS.log、Steam 辅助进程日志和状态、自动更新日志、VBMP 状态、从队友那里收到的日志、
# 存档备份列表、版本号。日志里有 Steam 昵称和 Windows 路径；不包含存档本身和 VBMP.ini。
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved')
)
$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $Dir 'VBMP_logs_export.txt'
try {
    $modDir = Split-Path $PSScriptRoot                  # ...\ue4ss\Mods\VBMP
    $ue4ssDir = Split-Path (Split-Path $modDir)         # ...\ue4ss
    $files = @()
    $files += Join-Path $ue4ssDir 'UE4SS.log'
    $files += Join-Path $modDir 'version.txt'
    foreach ($pattern in 'VBMP_steam.log', 'VBMP_steam_status.txt', 'VBMP_update.log', 'VBMP_update_status.txt',
        'VBMP_status*.txt', 'VBMP_peer_*.log', 'VBMP_backups.txt') {
        $files += Get-ChildItem -Path $Dir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tmp = Join-Path $env:TEMP "VBMP-logs-$stamp"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $n = 0
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        # the game keeps UE4SS.log open for writing: copy with shared read/write
        $src = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        try {
            $dst = [IO.File]::Create((Join-Path $tmp (Split-Path $f -Leaf)))
            try { $src.CopyTo($dst) } finally { $dst.Close() }
        } finally { $src.Close() }
        $n++
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path $desktop)) { $desktop = $Dir }
    $zip = Join-Path $desktop "VBMP-logs-$stamp.zip"
    Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($statusPath, "ok=$zip`nfiles=$n`n", (New-Object Text.UTF8Encoding($false)))
    Start-Process explorer.exe "/select,`"$zip`""
}
catch {
    [IO.File]::WriteAllText($statusPath, "error=" + $_.Exception.Message + "`n", (New-Object Text.UTF8Encoding($false)))
}
