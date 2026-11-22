# Sumeru 框架

可复用能力和使用经验随 `sumeru/` 目录一起迁移。项目专用资源、业务规则和美术规范留在项目中。

## 踩坑速查

遇到引擎或 UI 库的怪现象先看这里。哪个项目踩到新坑，先想能不能做进框架、默认就处理掉（像九宫格那条，带关闭开关）；做不进的写一行到这里，同步后每个项目都能看到。项目自己的业务坑留在项目里。

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 九宫格拉伸后，沿切片线有一条细线，颜色随背后画面变 | 官方九块分开画，每块边缘抗锯齿，接合处透出背后 | **框架已处理**：`UIKit:Attach` 默认装 `SliceSeams`，不用管。详见 [九宫格内部出现细线](toolkit/uikit/README.md#九宫格内部出现细线) |
| Label 按“字号 = 像素”估宽，总放不下 | `fontSize` 是 pt，画出来约 ×4/3 像素；`minFontSize` 只在 `UI.defaultAutoFitText` 打开时才生效 | 窄格子里按字数自己算字号：汉字算 1、数字和符号算 0.55，字号 = floor((格宽 − 2) ÷ (4/3) ÷ 字数)，再夹上下限 |
| `left: "-40%"` 往反方向跑 | 百分比解析丢掉负号，`"-40%"` 等于 `"40%"` | 负的 left / top / margin 一律写像素 |
| 比屏幕大几倍的滚动面板卡 | UI 库不做视口裁剪，屏幕外的也每帧画；ScrollView 每帧递归量内容大小 | 离屏子项设 `props.visibility = "hidden"`（别用 `SetVisible`，会整棵重排）；内容层定宽高时设 `overflow = "hidden"` |
| 试玩或截图脚本整屏黑，validate 却 PASS | 脚本里 `SubscribeToEvent("Update")` 顶掉了 App 的全局 Update（同一事件只留最后一个处理函数） | 每帧逻辑用定时续帧或 TickKit，别订全局 Update |
| `UI.Sprite{...}` 报 redundant-parameter、`SetStyle` 要字符串 | 类名 `Sprite` 跟引擎原生 UI 的 `Sprite` 撞名，LSP 认错 | 外面套一层 `UI.Panel`，挪位置、改大小走那层；构造那行 `---@diagnostic disable-next-line: redundant-parameter` |

## 事件中心

`arch.events`（`framework/TypeEvent.lua`）。注册进架构的对象自带 `SendEvent`、`PostEvent`、`RegisterEvent`、`UnRegisterEvent`、`UnRegisterAllEvent`。

- `obj:PostEvent(key, ...)`：先入队，由主循环每帧调一次 `arch.events:Drain()` 按序派发。**业务系统报告“发生了什么”用这个**，监听者不会插进一个动作的半路；派发时新 Post 的事件同一次处理，单次有上限，防止监听者互相 Post 成死循环。
- `obj:SendEvent(key, ...)`：当场派发，只用在发送方必须等监听者跑完的场合。
- key 必须是非空字符串，传错当场报错。事件名集中写成常量，别散落字符串。
- 监听者报错只打印，不影响发送方和其他监听者。测试里设 `arch.events.strict = true`，报错会重新抛出。
- 排查时设 `arch.events.trace = true`，打印每次派发。
- 开新局、读档时用 `arch.events:ClearQueue()` 丢掉上一局没派发的事件。

## 工具包文档

- [UIKit：面板宿主、弹窗栈、安全区 SafeArea、内置通用提示 Toast、UI 绘制经验与九宫格接缝](toolkit/uikit/README.md)
- [AnimationKit](toolkit/animation/README.md)
- [FSM](toolkit/fsm/README.md)
- [FloatingTextKit](toolkit/floatingtext/README.md)
- [AudioKit](toolkit/audiokit/README.md)
- [SaveKit：按结构声明合并的存档读写；CloudSync 云存档（clientCloud 多存一份，冲突让玩家选）](toolkit/savekit/README.md)
- [LoadKit：资源分包按需下载与后台预取](toolkit/loadkit/README.md)
- [AdKit：激励视频、免广与次数规则 AdFree、广告奖励统一入口 AdReward、电脑版提示移步手机端、广告位配置](toolkit/adkit/README.md)
- [EnvKit：运行环境（全局 Model "Env"），启动参数 -sumeru_dev 认测试环境，测试面板、广告跳过等测试功能按它开关](toolkit/envkit/README.md)
- [RedeemKit：兑换码，游戏内置码（存档记领取）+ TapTap 礼包无服务器兑换（Maker 真机需白名单）](toolkit/redeemkit/README.md)
- [RankKit：排行榜，clientCloud 整数云变量 + TapTap 昵称，只记历史最高，截图可模拟](toolkit/rankkit/README.md)
- [PoolKit：对象池与帧槽位池（按 System 注册）](toolkit/poolkit/README.md)
- [TickKit：更新调度、时间线倍速与暂停（按 System 注册）](toolkit/tickkit/README.md)

## 接入游戏项目

框架源码只在模板仓库 `Sumeru-TapMaker`（github.com/Losomz/Sumeru-TapMaker）里改，各 TapTap Maker 游戏项目保存一份同步副本于 `scripts/sumeru/`（普通文件，不用 git submodule，构建不受影响）。

- 同步：双击项目根目录的 `同步框架.cmd`，询问是否先更新框架，然后把框架和本地工具（`dev/sumeru/`）同步到当前项目，跑完停住看结果。
- Agent 免询问执行：`powershell -ExecutionPolicy Bypass -File .\dev\sumeru\sync.ps1 -Update`（或 `-NoUpdate`）。
- 框架仓库默认放在与游戏项目同级的 `Sumeru-TapMaker`，没有时自动克隆到那里。
- 项目根目录有 `.project/` 或 `.maker-mcp/` 才算游戏项目，还没远端构建过的项目也能双击同步；两样都没有的是框架仓库，要用 `-Project` 指定目标。新项目接入见模板仓库根目录 README。
- 框架改动在模板仓库提交、推送后，再到各项目双击同步，不要只改项目副本。
- `.meta` 含项目与作者信息，不入本仓库；同步后由各项目用 Maker MCP `generate_resource_meta` 为新文件生成。
- 项目的 UI 布局 `.ui.json` 一律放在 `assets/` 下（Maker 控制台只扫 `assets/`），Controller 放 `scripts/`；`dev/sumeru/ui-check.ps1` 在启动、截图、同步时自动检查。见 [Maker UI 目录与迁移说明](toolkit/uikit/MAKER_UI.md#规范)。
- 业务代码通过 `require("sumeru.toolkit.<kit>")` 引用；框架代码不引用任何业务模块，UIKit 的宿主与项目控件通过 `UIKit:Configure` 注入（见 [UIKit 接入配置](toolkit/uikit/README.md#接入配置)）。
