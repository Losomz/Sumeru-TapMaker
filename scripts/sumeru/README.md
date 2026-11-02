# Sumeru 框架

可复用能力和使用经验随 `sumeru/` 目录一起迁移。项目专用资源、业务规则和美术规范留在项目中。

## 工具包文档

- [UIKit：面板宿主、内置通用提示 Toast、UI 绘制经验与九宫格接缝](toolkit/uikit/README.md)
- [AnimationKit](toolkit/animation/README.md)
- [FSM](toolkit/fsm/README.md)
- [FloatingTextKit](toolkit/floatingtext/README.md)
- [AudioKit](toolkit/audiokit/README.md)
- [SaveKit：按结构声明合并的存档读写](toolkit/savekit/README.md)
- [LoadKit：资源分包按需下载与后台预取](toolkit/loadkit/README.md)
- [AdKit：激励视频与广告位配置](toolkit/adkit/README.md)
- [PoolKit：对象池与帧槽位池（按 System 注册）](toolkit/poolkit/README.md)

## 接入游戏项目

框架源码只在模板仓库 `Sumeru.TapMaker`（github.com/Losomz/Sumeru.TapMaker）里改，各 TapTap Maker 游戏项目保存一份同步副本于 `scripts/sumeru/`（普通文件，不用 git submodule，构建不受影响）。

- 同步：双击项目根目录的 `同步框架.cmd`，询问是否先更新框架，然后把框架和本地工具（`dev/sumeru/`）同步到当前项目，跑完停住看结果。
- Agent 免询问执行：`powershell -ExecutionPolicy Bypass -File .\dev\sumeru\sync.ps1 -Update`（或 `-NoUpdate`）。
- 框架仓库默认放在与游戏项目同级的 `Sumeru.TapMaker`，不存在时自动克隆。新项目接入见模板仓库根目录 README。
- 框架改动在模板仓库提交、推送后，再到各项目双击同步，不要只改项目副本。
- `.meta` 含项目与作者信息，不入本仓库；同步后由各项目用 Maker MCP `generate_resource_meta` 为新文件生成。
- 项目的 UI 布局 `.ui.json` 一律放在 `assets/` 下（Maker 控制台只扫 `assets/`），Controller 放 `scripts/`；`dev/sumeru/ui-check.ps1` 在启动、截图、同步时自动检查。见 [Maker UI 目录与迁移说明](toolkit/uikit/MAKER_UI.md#规范)。
- 业务代码通过 `require("sumeru.toolkit.<kit>")` 引用；框架代码不引用任何业务模块，UIKit 的宿主与项目控件通过 `UIKit:Configure` 注入（见 [UIKit 接入配置](toolkit/uikit/README.md#接入配置)）。
