# 游戏启动 Kit（BootKit）

`require("sumeru.toolkit.bootkit")` 负责游戏从 `Start()` 到第一个可玩画面之间的这一段：框架初始化 → 首屏包下载 → 游戏内容加载 → 交给游戏，期间显示**启动页**（进度、轮换短句、小提示、失败与重试）。

- 只依赖 `urhox-libs/UI`，**不依赖 UIKit**。游戏开始跑之后 UIKit 第一次刷新时挂上自己的根节点，自动换下启动页。
- 「加载」一词留给游戏内：分包下载（LoadKit）、进关卡前的素材下载提示、以后的加载遮罩都归游戏自己。BootKit 只管启动，界面叫「启动页」。
- 启动页是**布局模板**：逻辑固定在 BootKit 里，样式全在 `.ui.json`。别的项目复制模板换样式即可，不用改代码。

## 流程

```
BootKit:Start()
 1 框架初始化（同步）  UI.Init(ui) → setup()（游戏注册样式、控件、架构、分包，返回 LoadKit）→ 读布局，显示启动页
 2 首屏下载            LoadKit:Ensure(packs) 按顺序下；分批、自动重试、卡住重下      进度 0 → downloadShare（默认 85%）
 3 游戏内容（插槽）    steps 依次执行，每步可跨帧                                   进度 → 100%
 4 完成                onEvent("ready") → Prefetch(prefetch) → onDone()
```

任何一步失败都停在失败页，显示失败文案和按钮。下载失败时点按钮只重下失败的批次；某一步失败时点按钮从这一步重新开始。

## main.lua 接入模板

```lua
local UI=require("urhox-libs/UI")
local BootKit=require("sumeru.toolkit.bootkit")
local LoadKit=require("sumeru.toolkit.loadkit")

local app,boot

function Start()
 local arch,loads
 boot=BootKit.new({
  ui={theme="default-dark",scale=UI.Scale.DESIGN_SHORT_SIDE(480)},
  -- 框架初始化：样式、自定义控件（启动页布局里用到的必须在这里注册）、数据后台、架构、分包
  setup=function()
   Components.Register()
   arch=Sumeru.Architecture.MakeArchitecture("my-game")
   loads=LoadKit.new();loads:Define("boot",bootRefs);loads:Define("core",coreRefs)
   return loads
  end,
  layout="game/ui/boot/boot.ui.json",          -- 不写就用框架默认模板
  text={phrases={"正在生火…"},tips={"……"}},
  packs={"boot","core"},prefetch={"level2","audio"},
  -- 游戏内容加载：每步结束调 step:Done()，出错调 step:Fail(文案)（报错也会自动算失败）
  steps={
   {label="读档",start=function(step) arch:GetModel("Save"):Load(function() step:Done() end) end},
   {label="建场景",start=function(step) app=App.new(arch,loads);step:Done() end},
   {label="预热",weight=2,update=function(step,dt) step:Progress(k);if k>=1 then step:Done() end end},
  },
  onDone=function() app:Enter() end,
  onEvent=function(name,data) Telemetry.Boot(name,data) end,
 })
 boot:Start()
 SubscribeToEvent("Update","HandleUpdate")
end

function HandleUpdate(eventType,eventData)
 local dt=eventData["TimeStep"]:GetFloat()
 boot:Update(dt)
 if app and boot:IsDone() then app:Update(dt) end   -- 游戏这时接着每帧调 loads:Update(dt)
end
```

## 配置

| 字段 | 说明 |
|---|---|
| `ui` | 传给 `UI.Init`；游戏已自己初始化 UI 时不传 |
| `setup(kit)` | 框架初始化，返回 LoadKit；也可以直接给 `loads` |
| `layout` | 项目的启动页布局，读不到时退回框架默认模板并打日志 |
| `text` | `phrases` / `phraseEvery`（默认 1.6 秒）、`tips` / `tipEvery`（默认 6 秒）、`tipPrefix`（默认「小提示：」）、`errorColor`；`messages.retrying` / `failed`（`%d` 为失败项数）/ `step` 覆盖默认提示 |
| `packs` | 首屏包，按顺序下载 |
| `prefetch` | 启动完成后后台预取的包 |
| `downloadShare` | 下载段占进度的比例，默认 0.85；没有 `steps` 时为 1 |
| `steps` | `{label, weight?, start?(step), update?(step,dt)}`；`step:Progress(0..1)`、`step:Done()`、`step:Fail(text?)`。每步从下一帧开始，启动页先画出来 |
| `onDone(kit)` | 全部完成后调一次 |
| `onEvent(name,data)` | 埋点用，出错只打印，不影响启动 |

**事件**（`onEvent`）：

| name | data |
|---|---|
| `begin` | `{}` |
| `auto_retry` | `{pack, attempt}`：某批失败或卡住后自动重下。次数多时别逐条上报，`ready` / `fail` 里已带总数 |
| `fail` | `{stage, failed, retries, sec}`：`stage` 为 `download` 或步骤名 |
| `retry` | `{manual}`：玩家点了重试 |
| `ready` | `{sec, retries, manual}` |

**方法**：`Start()`、`Update(dt)`（每帧调；完成后只负责在启动页被换下后释放引用）、`IsDone()`、`State()`（new / downloading / content / failed / done）、`Progress()`、`Retry()`、`Release()`（项目不用 UIKit 时，在 `onDone` 之后调用，卸掉启动页）。

## 启动页模板

框架默认布局 `sumeru/toolkit/bootkit/boot.ui.json` 只用内置控件（Panel、Label、Button），是一个全屏的 flex 竖排：上方空图标区、进度条、百分比、短句，底部小提示和「重新下载」按钮。BootKit 只认下面这些 id，除了 `boot-root` 都可以删，缺了只打一次日志：

| id | BootKit 怎么用 |
|---|---|
| `boot-root` | 必须有。全屏底，底色、底图写在布局里；挡住点击 |
| `boot-icon` | 图标位，任意控件。每帧写 `props.progress`（0–100）和 `props.ready`（首包是否就绪）；控件有 `Tick(dt)` 就调用 |
| `boot-bar` / `boot-bar-fill` | 进度条：按进度设填充宽度百分比，平滑追上 |
| `boot-percent` | 百分比文字 |
| `boot-phrase` | 轮换短句（淡入淡出）；自动重试时显示 `messages.retrying`，失败时显示失败文案并换成 `errorColor` |
| `boot-tip` | 轮换小提示，失败时隐藏 |
| `boot-button` | 只在失败时显示，点了重试。没有这个 id 时点全屏任意处重试 |

- 短句和提示文字的**字色取布局里的 `fontColor`**，淡入淡出只改透明度；字体、字号、位置都在布局里。
- 失败文案可能两行：`boot-phrase` 留够高度，`whiteSpace` 设 `normal`、`verticalAlign` 设 `top`（默认模板就是这样）。

**换样式**：

1. 把 `scripts/sumeru/toolkit/bootkit/boot.ui.json` 复制到项目的 `assets/game/ui/boot/boot.ui.json`（项目布局一律放 `assets/`，见框架根目录 README）。
2. 用 Maker MCP `generate_resource_meta` 生成 `.meta`。
3. 改颜色、字号、位置、底图；图标位可以换成项目自己的控件（例如自带进度条的动画，这时删掉 `boot-bar`）。
4. 配置里写 `layout="game/ui/boot/boot.ui.json"`。

**注意**：

- 布局里用到的自定义控件，必须在 `setup` 里注册（`UI.LoadJSON` 按类型名找控件）。
- 启动页要用的字体、图标图、按钮底图必须放在**第一个首屏包**里（通常叫 `boot`，越小越好），否则启动页要等整个首屏下完才有字有图。图标控件可以读 `props.ready`，首包没好时只画不依赖贴图的部分。
- 框架模板不改；项目只改自己 `assets/` 下的副本。

## 和 LoadKit 的分工

- **LoadKit**：分包下载器，启动和游戏内都用（首屏包、后台预取、进关卡前 `Ensure`）。分批、自动重试、卡住检测都在这里，详见 `../loadkit/README.md`。
- **BootKit**：只在启动时用一次。它在启动期间每帧调 `loads:Update(dt)`，完成后不再推进，游戏要接着每帧调 `loads:Update(dt)`，后台预取和游戏内下载才有重试和卡住检测。

## 验证

- 截图场景可以在 `require("main")` 之前设 `LoadKit.DEFAULT.downloader` 为假下载器（实现 `DownloadResources(refs,onComplete,onProgress)` 和 `CancelDownloadGroup(group)`），并改短 `backoff` / `stall`，模拟下载中、重试中、失败、卡住。
- 日志前缀 `[BootKit]`：启动页已显示 → 首屏包就绪 → 开始/完成 各步 → 启动完成（用时、自动重试、手动重试）。
