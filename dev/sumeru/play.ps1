[CmdletBinding()]
param(
    # 临时覆盖 dev/launch.json 里的窗口宽高。
    [int]$Width = 0,
    [int]$Height = 0
)

# 本地启动游戏窗口：用 Maker 已安装的 UrhoXRuntime 运行 scripts/main.lua，只替换本工具上次启动的窗口。
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# UI 布局放错位置只提示，不拦启动。
& (Join-Path $PSScriptRoot "ui-check.ps1") -Quiet

$config = Get-LaunchConfig
if ($Width -gt 0) { $config.width = $Width }
if ($Height -gt 0) { $config.height = $Height }
$exe = Get-RuntimeExe

$old = Stop-OwnPreview
if ($old) { Write-Host "已关闭上一次的预览 PID=$old" }

# 运行时是 GUI 程序，Start-Process 不会多出控制台窗口；路径参数整体加引号，项目路径带空格也能用。
$arguments = @("main.lua", "`"-tapcode_dir=$ProjectRoot`"", "-skip_login", "-p=Res", "-w", "-width=$($config.width)", "-height=$($config.height)")
if ($config.orientation -eq "portrait") { $arguments += @("-portrait", "-no_rotate") }

$startedAt = Get-Date
$process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $ProjectRoot -PassThru
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PidFile) | Out-Null
Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ascii

# 从运行日志确认实际分辨率与配置的横竖屏一致。
$logDir = Join-Path (Split-Path -Parent $exe) "logs\game"
$mode = $null
$log = $null
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ($process.HasExited) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        throw "游戏进程提前退出，退出码：$($process.ExitCode)"
    }
    $log = Get-ChildItem -LiteralPath $logDir -File -Filter "urhox_runtime-*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $log) { continue }
    # 不用 -match/$Matches：日志读取失败或返回集合时 $Matches 不会被设置。
    $text = [string](Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue)
    $found = [regex]::Match($text, "Graphics mode:\s*(\d+)x(\d+)")
    if ($found.Success) { $mode = @([int]$found.Groups[1].Value, [int]$found.Groups[2].Value); break }
}

if (-not $mode) {
    Write-Warning "已启动，但 15 秒内没从运行日志确认分辨率。PID=$($process.Id)"
} else {
    $portrait = $mode[1] -gt $mode[0]
    if ($portrait -ne ($config.orientation -eq "portrait")) {
        Write-Warning "窗口方向与 dev/launch.json 的 orientation=$($config.orientation) 不一致：$($mode[0])x$($mode[1])"
    }
    Write-Host "已启动：$($mode[0])x$($mode[1])，PID=$($process.Id)"
}
if ($log) { Write-Host "日志：$($log.FullName)" }
