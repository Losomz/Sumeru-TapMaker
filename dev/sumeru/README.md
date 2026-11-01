# dev/sumeru：本地一键工具

随模板同步，项目里不要改；项目自己的配置写在 `dev/launch.json`。

| 做什么 | 双击 | PowerShell（项目根目录） | Git Bash（项目根目录） |
|---|---|---|---|
| 启动游戏窗口 | `启动游戏.cmd` | `.\启动游戏.cmd` 或 `.\dev\sumeru\play.ps1 [-Width 720 -Height 1280]` | `bash dev/sumeru/play.sh [宽] [高]` |
| 关闭游戏窗口 | `关闭游戏.cmd` | `.\关闭游戏.cmd` | `powershell -File dev/sumeru/stop.ps1` |
| 清除本游戏存档 | `清除存档.cmd` | `.\清除存档.cmd` | — |
| 截图 + 运行时报错检查 | — | — | `bash dev/sumeru/shot.sh <场景> [帧数] [宽] [高]` |
| 检查发布物料（出包前 / 出包后） | — | `.devsumerupublish-check.ps1` / `-Remote` | — |
| 同步框架与工具 | `同步框架.cmd` | `.\dev\sumeru\sync.ps1 -Update` 或 `-NoUpdate` | — |

## 约定
- `dev/launch.json`：`width`、`height`、`orientation`（`portrait`/`landscape`）、`savePrefix`（存档文件名前缀，默认项目文件夹名）。首次同步时按 `.project/project.json` 的 `screen_orientation` 生成。
- 启动：用 Maker 已安装的 UrhoXRuntime 运行 `scripts/main.lua`，PID 记在 `.tmp/local-preview.pid`。再次启动或关闭时，只关这个 PID，并校验它是 Maker 运行时，绝不按进程名批量关闭，以免误关其他游戏。启动后会从运行日志确认实际分辨率与横竖屏。
- 清存档：先关预览（避免退出时把存档写回），再删 `文档\temp\savedata` 下 `savePrefix` 开头的文件。
- 截图：运行 `scripts/dev/shot-<场景>.lua`（项目自己写，一般是设置场景后 `require("main")`），产出 `.tmp/shots/<场景>.png/.json/.log`，并打印过滤噪音后的脚本错误。
- Git Bash 不要用 `cmd //c 中文.cmd`（文件名会乱码），用上面的 `.sh` 入口。
- 发布物料：本地文件（`docs/publish-materials/`）、`project.json`（`assets`，有 `dc_publish_sync` 时还有 `baseFields`）、TapTap 草稿三处要一起改，只改本地会在上线时被 Maker 改回去。两张封面在 TapTap 的 `windows-exclusive` 模块，比例是 460:215 和 2:3。物料清单、换图步骤见 [publish/README.md](publish/README.md)。
- 运行时是 GUI 程序，启动不会多出控制台；双击 `.cmd` 的黑窗口成功即关，出错才停住。
