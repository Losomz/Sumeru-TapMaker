# EnvKit：运行环境（全局 Model "Env"）

`require("sumeru.toolkit.envkit")` 回答一个问题：现在是**测试环境**，还是玩家手里的**正式版**。测试面板、广告跳过这类只给测试用的东西，都按它开关。

## 怎么认测试环境

只认两种来源，没有就一律当正式版：

| 来源 | 谁加 | `Env.source` |
| --- | --- | --- |
| 启动参数 `-sumeru_dev` | 框架的 `dev/sumeru/play.ps1`（双击「启动游戏」）、`shot.sh`（截图、自检） | `"launch"` |
| 代码里 `Env.Enable(来源)` | 以后线上测试用，见下面「线上测试」 | 传进来的来源 |

- **不按平台猜**：TapTap PC 版也是桌面平台，按桌面开测试功能，PC 玩家会白拿广告奖励、数据被标成调试。
- **不认引擎参数**（`-tapcode_dir`、`-skip_login`）：那是宿主和 Maker 工具自己加的，哪天改了就认错。
- **认错只往安全的方向错**：漏了标识只是测试时看不了广告，不会白送玩家奖励。
- **Maker 自带的本地预览加不了参数**，按正式版处理（电脑上点广告会提示移步手机端）。要测试功能就用「启动游戏」或 `shot.sh`。
- 商店视频录屏（`dev/video/record.ps1` 一类）**不加**标识，画面和正式版一样。

## 接入

1. **注册成全局 Model**（`main.lua`，建好 arch 之后）：

   ```lua
   local Env=require("sumeru.toolkit.envkit")
   arch:RegisterModel("Env",Env)   -- 之后 self:GetModel("Env") 和 require 拿到的是同一张表
   ```

2. **按环境分的地方都问它**，不再用 `Platform.IsDesktopPlatform()`：

   ```lua
   Telemetry.Init(Env.IsDev())                                  -- 测试环境的事件标成调试数据
   local redeem=RedeemKit.new({...,userId=Env.IsDev() and function() return RedeemKit.UserId() or "desktop-test" end or nil})
   local ad=AdKit.new({sdk=sdk})                                -- 不传 simulate/blocked：广告跳过按 Has("skipAds")，电脑正式版自动拦下
   ```

3. **启动脚本带上 `-sumeru_dev`**：框架的 `play.ps1`、`shot.sh` 已经带了；项目自己写的测试启动脚本也要加。

## 接口

| 接口 | 说明 |
| --- | --- |
| `Env.dev` / `Env.IsDev()` | 是不是测试环境。「是不是测试」这类判断用它：数据标调试、兑换码测试账号 |
| `Env.Has(key)` | 测试功能开关：测试环境里默认都开，`Env.features[key]=false` 单独关 |
| `Env.IsPCRelease()` | 电脑上的正式版（TapTap PC），没有广告 |
| `Env.IsDesktop()` / `Env.IsMobile()` | 只看平台，画面、操作真的分手机和电脑时才用 |
| `Env.Enable(source)` | 打开测试环境，`source` 写来源（日志里会打印） |
| `Env.Override(dev)` | 自检用：`true` 当测试环境，`false` 当正式版，`nil` 恢复按启动参数 |
| `Env.source` | 怎么打开的，排查用 |

框架用到的测试功能 key：

| key | 管什么 |
| --- | --- |
| `skipAds` | 广告跳过：不播视频，直接按看完发奖（AdKit） |

想在测试环境里看真实的广告失败、电脑端提示，就 `Env.features.skipAds=false`。

## 加一个测试功能（模板）

游戏自己的测试功能（测试面板、秒升级、加钱……）都挂在 `Has` 上，key 自己起名：

```lua
-- 测试面板的入口：只有测试环境才建（OpenDevPanel、devButton 换成游戏自己的）
if Env.Has("panel") then devButton:SetVisible(true);devButton.onClick=OpenDevPanel end
```

- 一个功能一个 key，写在用到它的地方，不用提前登记。
- 正式版里 `Has` 一律是 false，测试代码可以留在包里；但别把测试按钮做成默认可见再靠隐藏，入口本身就按 `Has` 决定建不建。
- 截图场景（`shot.sh`）也是测试环境。测试面板这类入口如果不想出现在截图里，截图场景里 `Env.features.panel=false`。

## 线上测试（以后用）

真机、TapTap PC 客户端都没有启动参数，要在线上打开测试环境，就在确认是测试人员之后调 `Env.Enable("来源")`。常见做法：

- 测试账号白名单：读完 TapTap 用户 ID 后比对配置里的名单，`Env.Enable("whitelist")`；
- 隐藏入口：比如在兑换码里输一个测试口令，`Env.Enable("redeem")`。

打开后广告跳过、测试面板立即生效（AdKit 每次请求时才问 EnvKit）。名单、口令只给测试人员；知道的人都能白拿广告奖励。

## 自检

```lua
local Env=require("sumeru.toolkit.envkit")
check(Env.IsDev() and Env.source=="launch","shot.sh 带了 -sumeru_dev")
Env.Override(false)        -- 当成正式版，在桌面上就是电脑正式版
check(Env.IsPCRelease() and not Env.Has("skipAds"),"正式版：没有测试功能，电脑上拦广告")
Env.Override(nil)          -- 恢复
```
