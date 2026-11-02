[CmdletBinding()]
param(
    # 游戏项目根目录，默认本脚本所在的项目。
    [string]$Project = "",
    # 没有问题时不输出。
    [switch]$Quiet
)

# UI 布局检查：Maker 控制台的 UI 编辑器只扫 assets/，放在 scripts/ 下的 .ui.json 游戏能读，后台却看不到。
# 只读，不改文件。有问题时列出清单和改法，退出码 1；没问题退出码 0。启动游戏、同步框架时会自动跑一次。
$ErrorActionPreference = "Stop"
if (-not $Project) { $Project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Project = (Resolve-Path -LiteralPath $Project).Path

# 返回目录下全部 .ui.json 的项目相对路径（正斜杠）；目录不存在时为空。
function Get-Layouts([string]$dir) {
    $root = Join-Path $Project $dir
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $prefix = (Get-Item -LiteralPath $root).FullName.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Name.EndsWith(".ui.json", [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { "$dir/" + ($_.FullName.Substring($prefix.Length) -replace '\\', '/') }
}

# 框架自己的布局（scripts/sumeru/，如 toast）随框架同步，项目不改，不算放错。
$misplaced = @(Get-Layouts "scripts" | Where-Object { $_ -notlike "scripts/sumeru/*" })
$layouts = @(Get-Layouts "assets")
$noMeta = @($layouts | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Project "$_.meta")) })

if ($misplaced.Count -gt 0) {
    Write-Warning "以下 $($misplaced.Count) 份 UI 布局放在 scripts/ 下，Maker 控制台的 UI 编辑器看不到（它只扫 assets/）："
    $misplaced | ForEach-Object { Write-Host "  $_" }
    Write-Host "  改法：连同 .meta 用 git mv 平移到 assets/ 下同一相对路径，资源路径不变，代码不用改。"
    Write-Host "  例：scripts/game/ui/panels/home/home.ui.json -> assets/game/ui/panels/home/home.ui.json"
    Write-Host "  说明见 scripts/sumeru/toolkit/uikit/MAKER_UI.md"
}
if ($noMeta.Count -gt 0) {
    Write-Warning "以下 $($noMeta.Count) 份 UI 布局缺少 .meta，请用 Maker MCP generate_resource_meta 生成（不要手写 UUID）："
    $noMeta | ForEach-Object { Write-Host "  $_" }
}
if ($misplaced.Count -gt 0 -or $noMeta.Count -gt 0) { exit 1 }
if (-not $Quiet) { Write-Host "UI 布局检查通过：assets/ 下 $($layouts.Count) 份，scripts/ 下没有项目布局" }
exit 0
