# Sumeru TapMaker 项目模板

TapTap Maker 游戏的起手模板：sumeru 框架 + 本地一键工具。仓库根目录就是游戏项目根目录的样子，复制进新项目即可用。

```
启动游戏.cmd / 关闭游戏.cmd / 清除存档.cmd / 同步框架.cmd   根目录一键脚本
scripts/sumeru/                            框架（UIKit、SaveKit、LoadKit、FSM、Animation……），见 scripts/sumeru/README.md
dev/sumeru/                                本地工具（启动、关闭、清存档、截图自检、同步、初始化、发布物料检查），见 dev/sumeru/README.md
dev/sumeru/publish/                        发布经验与模板：Maker 与 TapTap 物料保持一致，见 dev/sumeru/publish/README.md
```

## 新项目接入
1. 用 Maker 创建并绑定项目（`taptap-maker init`），得到带 `.project/` 的项目目录。
2. 二选一：
   - 在本仓库运行 `powershell -ExecutionPolicy Bypass -File .\dev\sumeru\sync.ps1 -Project <项目根目录> -NoUpdate`；
   - 或者把本仓库内容（除 `.git`、`README.md`）复制到项目根目录，再双击项目里的 `同步框架.cmd`。
3. 同步会自动运行 `dev/sumeru/setup.ps1`，补齐：
   - `dev/launch.json`：窗口尺寸、横竖屏、存档前缀；
   - `.project/settings.json` 的构建忽略；
   - `.gitattributes` 换行规则、`.gitignore` 的 `.tmp/`；
   - `docs/publish-materials/`（发布物料）与 `docs/更新日志/`（论坛公告）模板。
4. 按同步结果的提示，用 Maker MCP `generate_resource_meta` 给 `scripts/sumeru/` 下缺 `.meta` 的文件生成 `.meta`。
5. 照 `scripts/sumeru/toolkit/bootkit/README.md` 的模板写 `scripts/main.lua`（启动页、首屏包、读档等交给 BootKit）；要换启动页样式就把模板布局复制到 `assets/game/ui/boot/`。写好后双击 `启动游戏.cmd`。
6. 上架前读 `dev/sumeru/publish/README.md`：图片放进 `docs/publish-materials/`，出包前后各跑一次 `publish-check.ps1`。

## UI 布局与 Maker 编辑器

**规范：项目的 `.ui.json` 一律放在 `assets/` 下，`scripts/` 只放 Lua。** Maker 编辑器只递归扫描 `assets/`，不会发现 `scripts/` 中的 `.ui.json`；游戏能加载 JSON，并不代表后台能找到它。

- 新项目放 `assets/ui/`。老项目把布局连同 `.meta` 平移到 `assets/` 下与 Controller 相同的相对路径，代码不用改。
- 唯一例外是框架自己的布局（`scripts/sumeru/` 下，如 Toast），随框架同步，项目不改。
- 新建布局后用 Maker MCP `generate_resource_meta` 生成 `.meta`，再用 `taptap-maker ui list --target-dir <项目> --json` 确认后台能看到。
- 自动检查 `dev/sumeru/ui-check.ps1`：启动游戏、截图、同步框架时都会跑，`scripts/` 下有项目布局或 `assets/` 下的布局缺 `.meta` 就提示。

目录示例、旧项目迁移、资源 UUID 保留和自定义控件的编辑器限制见 [Maker UI 目录与迁移说明](scripts/sumeru/toolkit/uikit/MAKER_UI.md)。

## 维护
- 框架和工具只在本仓库改，提交推送后到各项目双击 `同步框架.cmd`；不要只改项目里的副本。
- 同步时 `scripts/sumeru/`、`dev/sumeru/` 整目录镜像（本仓库删掉的文件，项目里也会删）；根目录 `.cmd` 只覆盖不删；项目自己的 `dev/launch.json` 不动。
- 老项目（同步器还在 `scripts/sumeru/sync.ps1` 的旧结构）不要再双击旧的 `scripts/sumeru/同步框架.cmd`，它会把新结构整个复制进 `scripts/sumeru/`。在本仓库用 `-Project` 迁移一次即可。
- `.meta` 含项目与作者信息，不入本仓库。
