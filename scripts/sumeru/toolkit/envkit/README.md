# EnvKit：运行环境

`require("sumeru.toolkit.envkit")` 回答两个问题：现在是不是本地开发、是不是玩家的电脑正式版。

**TapTap PC 版也是桌面平台**，所以不能拿 `Platform.IsDesktopPlatform()` 当「本地开发」。按桌面开的东西，PC 玩家全会碰到：模拟广告直接发奖、排行榜显示假榜、数据后台的事件被标成调试数据、兑换码共用一个测试账号。

| 函数 | 什么时候为真 |
| --- | --- |
| `IsLocalDev()` | 桌面平台，并且启动参数带 `-tapcode_dir=`（直接跑本地源码目录）。Maker 本地预览、`dev/sumeru/play.ps1`、`shot.sh` 都带；正式版从游戏包启动，不带 |
| `IsPCRelease()` | 桌面平台，但不是本地开发：玩家在 TapTap PC 上玩 |
| `IsDesktop()` / `IsMobile()` | 只看平台（Windows、Linux、Mac / Android、iOS、HarmonyOS） |
| `Override(dev)` | 测试用：`true` 当成本地开发，`false` 当成正式版，`nil` 恢复按启动参数判断 |

```lua
local Env=require("sumeru.toolkit.envkit")

Telemetry.Init(Env.IsLocalDev())          -- 只有本地开发的事件标成调试数据
local redeem=RedeemKit.new({...,userId=Env.IsLocalDev() and function() return RedeemKit.UserId() or "desktop-test" end or nil})
```

- 广告不用自己判断：`AdKit` 默认本地开发时模拟、PC 正式版时拦下，`AdReward` 提示「因设备限制，无法观看广告，请移步手机端」（见 [AdKit](../adkit/README.md#电脑版)）。
- 只想「本地开发才做」的事都用 `IsLocalDev()`；只有画面、操作上真的分手机和电脑（比如鼠标悬停）才看 `IsDesktop()`。
- 自己写启动脚本时用 `-tapcode_dir=<项目目录>` 跑源码，否则会被当成 PC 正式版（看不了广告）。本地跑远端包（`-game_url=`）也算正式版。
- 为什么不认 `-skip_login`：PC 客户端登录过后也可能带它。认错成本地开发会模拟广告、白送奖励；认错成正式版只是看不了广告，开发时一眼能发现，所以只认更严的那个。
