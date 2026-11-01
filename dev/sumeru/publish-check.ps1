# 发布物料检查：核对 docs/publish-materials/、.project/project.json（assets 和 dc_publish_sync.baseFields）是否一致、合规，-Remote 时再读 TapTap 草稿比对。只读，不改任何文件。
# 规则说明见 dev/sumeru/publish/README.md。
param([switch]$Remote)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Drawing

$projectJson = Join-Path $ProjectRoot ".project\project.json"
if (-not (Test-Path -LiteralPath $projectJson)) { throw "找不到 .project/project.json，先用 Maker 绑定项目。" }
$project = [System.IO.File]::ReadAllText($projectJson) | ConvertFrom-Json
$assets = $project.assets
$publish = $project.taptap_publish
$cdn = "https://tapcode-sce.spark.xd.com/assets/game_material/$($project.project_id)/"
$tmp = Join-Path $ProjectRoot ".tmp\publish-check"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:errors = 0; $script:warnings = 0

# 输出一条检查结果并计数。
function Report([string]$level, [string]$name, [string]$message) {
    $color = @{ OK = "Green"; WARN = "Yellow"; ERROR = "Red"; INFO = "Gray" }[$level]
    if ($level -eq "ERROR") { $script:errors++ } elseif ($level -eq "WARN") { $script:warnings++ }
    Write-Host ("[{0}] {1}：{2}" -f $level, $name, $message) -ForegroundColor $color
}

# 请求地址是否返回 200。
function Test-Url([string]$url) {
    try { return (Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20).StatusCode -eq 200 } catch { return $false }
}

# 读取图片宽高，失败返回 $null。
function Get-ImageSize([string]$path) {
    try { $image = [System.Drawing.Image]::FromFile($path) } catch { return $null }
    try { return @($image.Width, $image.Height) } finally { $image.Dispose() }
}

# 下载地址上的图片并返回宽高，失败返回 $null。
function Get-RemoteImageSize([string]$url, [string]$name) {
    $file = Join-Path $tmp ($name + [System.IO.Path]::GetExtension(($url -split '\?')[0]))
    try { Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -TimeoutSec 60 } catch { return $null }
    return Get-ImageSize $file
}

# 检查一个本地路径：能否被 Maker 上传、文件是否存在、尺寸是否符合 TapTap 要求；返回本地文件绝对路径（无法核对时为 $null）。
function Test-AssetPath([string]$name, [string]$path, [bool]$required, $spec) {
    if (-not $path) {
        if ($required) { Report ERROR $name "本地路径为空，管理发布会报「assets 缺少 $name 字段」，无法上传" } else { Report WARN $name "本地路径为空，TapTap 上这一项不会更新" }
        return $null
    }
    $rel = $path -replace '^\./', ''
    if ($rel -like "game_material/*") {
        Report WARN $name "指向 Maker 服务器上的 $rel，本地无法核对。多半是 Maker 生成的旧图，出包会把它传到 TapTap，覆盖后台的修改；建议换成 docs/publish-materials/ 里的文件"
        return $null
    }
    if ($rel -like "_uploads/*") {
        $leaf = Split-Path -Leaf $rel
        if (-not (Test-Url ($cdn + $leaf))) {
            Report ERROR $name "$rel 不是在 Maker 网页上传的文件（CDN 上没有），Maker 同步会把它删掉；自己的图放到 docs/publish-materials/"
            return $null
        }
    }
    $full = Join-Path $ProjectRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { Report ERROR $name "文件不存在：$rel"; return $null }
    $size = Get-ImageSize $full
    if (-not $size) { Report ERROR $name "不是有效图片：$rel"; return $null }
    $bytes = (Get-Item -LiteralPath $full).Length
    $problems = @()
    if ($spec) {
        if ($size[0] -lt $spec.MinW -or $size[1] -lt $spec.MinH) { $problems += "尺寸 $($size[0])x$($size[1]) 小于 $($spec.MinW)x$($spec.MinH)" }
        if ($spec.Ratio -and [math]::Abs($size[0] / $size[1] - $spec.Ratio) -gt 0.02) { $problems += "比例不是 $($spec.RatioText)" }
        if ($spec.MaxMB -and $bytes -gt $spec.MaxMB * 1MB) { $problems += ("{0:N1}MB 超过 {1}MB" -f ($bytes / 1MB), $spec.MaxMB) }
    }
    if ($problems.Count -gt 0) { Report ERROR $name ("$rel " + ($problems -join "，")) } else { Report OK $name "$rel（$($size[0])x$($size[1])）" }
    return $full
}

# 检查 *_url 与本地文件是否像同一张图：地址能访问且宽高一致。
function Test-AssetUrl([string]$name, [string]$url, [string]$local) {
    if (-not $url) { Report WARN "${name}_url" "为空，Maker 管理发布页这一项显示为空"; return }
    if (-not $local) { return }
    $remote = Get-RemoteImageSize $url "$name-url"
    $size = Get-ImageSize $local
    if (-not $remote) { Report ERROR "${name}_url" "地址打不开：$url"; return }
    if ($remote[0] -ne $size[0] -or $remote[1] -ne $size[1]) {
        Report WARN "${name}_url" "地址上的图是 $($remote[0])x$($remote[1])，本地文件是 $($size[0])x$($size[1])：网页显示的图和实际上传的图不是同一张"
    }
}

# 调用 taptap-cli 并解析 JSON 输出：参数 JSON 写进项目内临时文件用 @file 传入（命令行传 JSON 会被 PowerShell 吃掉引号），stderr 不当作致命错误。
# taptap-cli 输出 UTF-8；中文 Windows 默认按 GBK 解码，中文会把 JSON 的引号吞掉导致解析失败，所以调用期间临时切到 UTF-8。
function Invoke-TapCli([string[]]$arguments, [string]$data) {
    $dataFile = Join-Path $tmp "data.json"
    [System.IO.File]::WriteAllText($dataFile, $data, (New-Object System.Text.UTF8Encoding($false)))
    $saved = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $savedEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    Push-Location $ProjectRoot
    try { $raw = (& taptap-cli @arguments --data "@.tmp/publish-check/data.json" 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    finally { Pop-Location; [Console]::OutputEncoding = $savedEncoding; $ErrorActionPreference = $saved }
    $start = $raw.IndexOf("{")
    if ($start -lt 0) { return [pscustomobject]@{ ok = $false; error = [pscustomobject]@{ message = $raw } } }
    try { return $raw.Substring($start) | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = [pscustomobject]@{ message = $raw } } }
}

Write-Host "== 本地物料（docs/publish-materials/ 与 assets）=="
$specs = @{
    icon = @{ MinW = 512; MinH = 512; Ratio = 1; RatioText = "1:1" }
    promotional_image = @{ MinW = 1920; MinH = 1080; Ratio = 16 / 9; RatioText = "16:9"; MaxMB = 4 }
    square_promotional_image = @{ MinW = 1440; MinH = 1440; Ratio = 1; RatioText = "1:1"; MaxMB = 4 }
    # 封面是 TapTap「Windows 素材」模块的 cover / cover_vertical，比例不是 16:9 / 9:16。
    cover_horizontal = @{ MinW = 460; MinH = 215; Ratio = 460 / 215; RatioText = "460:215" }
    cover_vertical = @{ MinW = 600; MinH = 900; Ratio = 2 / 3; RatioText = "2:3" }
}
foreach ($name in @("icon", "promotional_image", "square_promotional_image", "cover_horizontal", "cover_vertical")) {
    $local = Test-AssetPath $name $assets.$name ($name -eq "icon") $specs[$name]
    Test-AssetUrl $name $assets."${name}_url" $local
}
$shots = @($assets.screenshots | Where-Object { $_ })
if ($shots.Count -lt 3) { Report ERROR "screenshots" "只有 $($shots.Count) 张，TapTap 至少要 3 张" }
for ($i = 0; $i -lt $shots.Count; $i++) { [void](Test-AssetPath "screenshots[$($i + 1)]" $shots[$i] $true $null) }
$shotUrls = @($assets.screenshot_urls | Where-Object { $_ })
if ($shotUrls.Count -ne $shots.Count) { Report WARN "screenshot_urls" "有 $($shotUrls.Count) 个地址，和 $($shots.Count) 张截图数量不一致，网页显示的截图和实际上传的不同" }

# Maker 发布记录：有 dc_publish_sync 时，管理发布页显示 TapTap 草稿里的图，上线时按草稿改写 assets 和 baseFields。
# baseFields 和 assets 不一致，说明新图还没写进草稿，上线会被改回去。
$sync = $project.dc_publish_sync
if ($sync -and $sync.baseFields) {
    Write-Host ""
    Write-Host "== Maker 发布记录（dc_publish_sync.baseFields）=="
    $basePairs = @(
        @("icon_url", "icon_url"),
        @("banner_url", "promotional_image_url"),
        @("square_promo_url", "square_promotional_image_url"),
        @("cover_horizontal_url", "cover_horizontal_url"),
        @("cover_vertical_url", "cover_vertical_url")
    )
    foreach ($pair in $basePairs) {
        $base = "$($sync.baseFields.($pair[0]))"
        $want = "$($assets.($pair[1]))"
        if ($base -eq $want) { Report OK "baseFields.$($pair[0])" "与 assets.$($pair[1]) 一致" }
        elseif ($sync.pending -and "$($sync.pending.($pair[0]))" -eq $want) { Report INFO "baseFields.$($pair[0])" "管理发布页改过、还没上线（记在 dc_publish_sync.pending），TapTap 草稿已是这张；上线后看 Maker 同步提交" }
        else { Report WARN "baseFields.$($pair[0])" "和 assets.$($pair[1]) 不同：新图要先写进 TapTap 草稿，再把这里改成同一个地址，否则上线时会被改回去（见 dev/sumeru/publish/README.md 换图步骤）" }
    }
}

if ($Remote) {
    Write-Host ""
    Write-Host "== TapTap 草稿（taptap-cli 只读）=="
    if (-not (Get-Command taptap-cli -ErrorAction SilentlyContinue)) {
        Report ERROR "taptap-cli" "未安装，先 npm i -g @taptap/cli 并登录"
    } elseif (-not $publish.developer_id -or -not $publish.app_id) {
        Report ERROR "taptap_publish" "缺少 developer_id 或 app_id，先在 Maker 管理发布页完成一次发布"
    } else {
        $fields = @{}
        $hasDraft = $true
        foreach ($module in @("basic-info", "assets-upload", "windows-exclusive")) {
            $result = Invoke-TapCli @("app", "get-app-module", "--dev-id", $publish.developer_id, "--app-id", $publish.app_id) "{`"module_id`":`"$module`"}"
            # windows-exclusive（Windows 素材，含两张封面）不是每个应用都有，读不到只提示。
            if (-not $result.ok -and $module -eq "windows-exclusive") { Report INFO $module ("读取失败，跳过封面比对：" + $result.error.message); continue }
            if (-not $result.ok) { Report ERROR $module ("读取失败：" + $result.error.message); $hasDraft = $false; continue }
            if (-not $result.data.result.revision) { $hasDraft = $false }
            foreach ($p in $result.data.result.fields.PSObject.Properties) { $fields[$p.Name] = $p.Value.current_value }
        }
    }
    if ($fields -and -not $hasDraft) {
        Report INFO "TapTap 草稿" "当前没有未发布草稿（已上线版本无法读取），Maker 出包后再运行 -Remote 核对"
    } elseif ($fields) {
        # 比较 TapTap 草稿字段和 project.json 的期望值，一致才通过。
        $pairs = @(
            @("title", $fields["title"], $publish.title),
            @("description", $fields["description"], $publish.description),
            @("category", $fields["category"], $publish.category),
            @("icon", $fields["icon"], $assets.icon_url),
            @("banner_4", $fields["banner_4"], $assets.promotional_image_url),
            @("square_promo_image", $fields["square_promo_image"], $assets.square_promotional_image_url)
        )
        if ($fields.ContainsKey("cover_vertical")) {
            $pairs += ,@("cover", $fields["cover"], $assets.cover_horizontal_url)
            $pairs += ,@("cover_vertical", $fields["cover_vertical"], $assets.cover_vertical_url)
        }
        foreach ($pair in $pairs) {
            if ("$($pair[1])" -eq "$($pair[2])") { Report OK $pair[0] "与 project.json 一致" }
            else { Report WARN $pair[0] "TapTap：$($pair[1])`n        期望：$($pair[2])" }
        }
        $draftShots = @($fields["screenshots"] | Where-Object { $_ })
        Report INFO "screenshots" ("TapTap 草稿 {0} 张，本地 {1} 张；截图地址两边不同（TapTap 会转存），请人工确认是实机截图" -f $draftShots.Count, $shots.Count)
    }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("错误 {0}，警告 {1}" -f $script:errors, $script:warnings)
if ($script:errors -gt 0) { exit 1 }
