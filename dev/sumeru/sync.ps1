[CmdletBinding()]
param(
    # 框架仓库本地路径，默认找与游戏项目同级的 Sumeru.TapMaker 或 sumeru-tapmaker。
    [string]$Source = "",
    # 目标游戏项目根目录；在框架仓库里运行时必填（安装到新项目或迁移老项目）。
    [string]$Project = "",
    # 直接更新框架到最新，不询问。
    [switch]$Update,
    # 直接用本地框架同步，不更新、不询问。
    [switch]$NoUpdate
)

# Sumeru 模板同步器：把框架（scripts/sumeru/）、模板工具（dev/sumeru/）和根目录一键脚本同步进游戏项目，连同自身一起更新。
# 项目里双击根目录「同步框架.cmd」运行；在框架仓库里用 -Project 指定目标项目。
$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/Losomz/Sumeru.TapMaker.git"
# 推送走 SSH：拉取公开仓库用 HTTPS 不用登录，推送走 HTTPS 会弹 GitHub 登录窗口。
$pushUrl = "git@github.com:Losomz/Sumeru.TapMaker.git"
if ((Split-Path -Leaf $PSScriptRoot) -ne "sumeru" -or (Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)) -ne "dev") {
    throw "同步器必须位于 dev/sumeru/ 目录：$PSScriptRoot"
}
$here = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# 游戏项目有 Maker 的 .project/（远端构建过才有）或 .maker-mcp/（绑定后就有），框架仓库两样都没有。
# 只认 .project/ 的话，还没远端构建过的项目会被当成框架仓库。
function Test-GameProject([string]$dir) {
    (Test-Path -LiteralPath (Join-Path $dir ".project")) -or (Test-Path -LiteralPath (Join-Path $dir ".maker-mcp"))
}

# 在框架仓库里运行时源就是本仓库，目标必须用 -Project 指定。
if (-not (Test-GameProject $here)) {
    if (-not $Project) { throw "这里是框架仓库，请用 -Project 指定游戏项目根目录" }
    if (-not $Source) { $Source = $here }
}
if (-not $Project) { $Project = $here }
$Project = (Resolve-Path -LiteralPath $Project).Path
if (-not (Test-Path -LiteralPath (Join-Path $Project "scripts"))) { throw "不是游戏项目（缺少 scripts/）：$Project" }
# 默认用与游戏项目同级的框架仓库，两种目录名都认；都没有才克隆到 Sumeru.TapMaker。
if (-not $Source) {
    $parent = Split-Path -Parent $Project
    $Source = Join-Path $parent "Sumeru.TapMaker"
    foreach ($name in @("Sumeru.TapMaker", "sumeru-tapmaker")) {
        $candidate = Join-Path $parent $name
        if ((Test-Path -LiteralPath (Join-Path $candidate ".git")) -and
            (Test-Path -LiteralPath (Join-Path $candidate "dev\sumeru\sync.ps1"))) {
            $Source = $candidate
            break
        }
    }
}

# 框架仓库不存在时克隆；存在时按参数或询问决定是否快进拉取，避免覆盖本地未推送的框架改动。
if (-not (Test-Path -LiteralPath (Join-Path $Source ".git"))) {
    Write-Host "克隆框架仓库到 $Source"
    git clone $repoUrl $Source
    if ($LASTEXITCODE -ne 0) { throw "克隆框架仓库失败" }
} else {
    $pull = $Update
    if (-not $Update -and -not $NoUpdate) {
        $answer = Read-Host "是否先更新框架到最新？[Y/n]"
        $pull = $answer -notmatch '^[nN]'
    }
    if ($pull) {
        git -C $Source pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "更新框架仓库失败" }
    }
}
# 推送地址还是默认 HTTPS 时改成 SSH，只改推送、拉取照旧；自己改过的地址不动。
$currentPush = ""
try { $currentPush = (git -C $Source remote get-url --push origin 2>$null) } catch { }
if ($currentPush -eq $repoUrl) {
    git -C $Source remote set-url --push origin $pushUrl
    Write-Host "框架仓库推送地址改为 SSH：$pushUrl"
}
$Source = (Resolve-Path -LiteralPath $Source).Path
if ($Source -eq $Project) { throw "目标项目不能是框架仓库本身" }

# 返回目录下需要同步的文件相对路径，不含 .meta；目录不存在时为空。
function Get-SyncFiles([string]$root) {
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    # 前缀与 Get-ChildItem 同源取得，避免 8.3 短路径与长路径长度不一致。
    $prefix = (Get-Item -LiteralPath $root).FullName.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -ne '.meta' } |
        ForEach-Object { $_.FullName.Substring($prefix.Length) }
}

# 按字节比较两个文件内容是否一致（Windows PowerShell 5 不保证有 Get-FileHash）。
function Test-SameContent([string]$a, [string]$b) {
    $x = [System.IO.File]::ReadAllBytes($a)
    $y = [System.IO.File]::ReadAllBytes($b)
    return [System.Linq.Enumerable]::SequenceEqual($x, $y)
}

$script:added = @(); $script:updated = @(); $script:removed = @()

# 源文件新增或内容变化时覆盖到项目；已有 .meta 保持不动。
function Copy-Synced([string]$from, [string]$to, [string]$label) {
    if (-not (Test-Path -LiteralPath $to)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $from -Destination $to
        $script:added += $label
    } elseif (-not (Test-SameContent $from $to)) {
        Copy-Item -LiteralPath $from -Destination $to -Force
        $script:updated += $label
    }
}

# 托管目录整目录镜像：源里删掉的文件连同 .meta 一起从项目移除，再清理孤立 .meta 与空目录。
foreach ($dir in @("scripts\sumeru", "dev\sumeru")) {
    $from = Join-Path $Source $dir
    $to = Join-Path $Project $dir
    $sourceSet = @{}
    foreach ($rel in @(Get-SyncFiles $from)) {
        $sourceSet[$rel.ToLowerInvariant()] = $true
        Copy-Synced (Join-Path $from $rel) (Join-Path $to $rel) (Join-Path $dir $rel)
    }
    foreach ($rel in @(Get-SyncFiles $to)) {
        if (-not $sourceSet.ContainsKey($rel.ToLowerInvariant())) {
            $path = Join-Path $to $rel
            Remove-Item -LiteralPath $path -Force
            Remove-Item -LiteralPath ($path + ".meta") -Force -ErrorAction SilentlyContinue
            $script:removed += (Join-Path $dir $rel)
        }
    }
    Get-ChildItem -LiteralPath $to -Recurse -File -Filter *.meta |
        Where-Object { -not (Test-Path -LiteralPath ($_.FullName.Substring(0, $_.FullName.Length - 5))) } |
        Remove-Item -Force
    Get-ChildItem -LiteralPath $to -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
        Remove-Item -Force
}

# 根目录一键脚本只覆盖不删除。
foreach ($file in @(Get-ChildItem -LiteralPath $Source -File -Filter *.cmd)) {
    Copy-Synced $file.FullName (Join-Path $Project $file.Name) $file.Name
}

# git 输出 UTF-8，Windows PowerShell 默认按 GBK 解码，提交说明会乱码。
$encoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$commit = (git -C $Source log -1 --format="%h %s").Trim()
[Console]::OutputEncoding = $encoding
Write-Host "项目：$Project"
Write-Host "框架版本：$commit"
Write-Host ("新增 {0}，更新 {1}，删除 {2}" -f $script:added.Count, $script:updated.Count, $script:removed.Count)
$script:added + $script:updated + $script:removed | ForEach-Object { Write-Host "  $_" }

# 补齐项目配置（launch.json、构建忽略、换行规则），只补缺不覆盖。
& (Join-Path $Project "dev\sumeru\setup.ps1")

# UI 布局要放在 assets/，Maker 控制台才看得到；放错只提示。
& (Join-Path $Project "dev\sumeru\ui-check.ps1") -Project $Project

# 列出缺少 .meta 的框架脚本（文档不需要），交由 Maker MCP generate_resource_meta 生成；dev/ 不是资源目录，不需要 .meta。
$missing = @(Get-SyncFiles (Join-Path $Project "scripts\sumeru") | Where-Object {
    $_ -notmatch '\.md$' -and -not (Test-Path -LiteralPath ((Join-Path $Project "scripts\sumeru\$_") + ".meta"))
})
if ($missing.Count -gt 0) {
    Write-Host "以下文件缺少 .meta，请用 Maker MCP generate_resource_meta 生成："
    $missing | ForEach-Object { Write-Host ("  scripts/sumeru/" + ($_ -replace '\\', '/')) }
}
