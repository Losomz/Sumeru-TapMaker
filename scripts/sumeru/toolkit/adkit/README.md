# AdKit：激励视频

`require("sumeru.toolkit.adkit")` 返回激励视频适配层，统一 `sdk:ShowRewardVideoAd` 的忙状态、同步拒绝、重复回调与失败兜底。

```lua
local AdKit=require("sumeru.toolkit.adkit")
local ad=AdKit.new({sdk=sdk,simulate=Platform.IsDesktopPlatform()})

if ad:CanRequest() then
    ad:ShowRewardVideo(function(result)
        if result.success then GrantReward() else ShowNotice("广告播放失败，请稍后重试") end
    end)
end
```

- 只有 `result.success==true` 才发奖；`"embed manual close"`（提前关闭）也是失败。
- 每次请求只回调一次；播放期间 `IsBusy()` 为真，重复点击直接返回 `false`。
- 失败时日志会打印 `[AdKit] 广告未完成 msg=...`，这是宿主/SDK 的原始结果，排查先看这一行。
- `simulate=true`（桌面本地开发）不调用宿主，直接按完整观看回调，只用来走通奖励链路。

## 免广与次数：AdFree + AdReward

广告点（按钮）只管触发结算，不判断免广，也不自己计次；免广由入口自己控制。

- `AdFree`（`sumeru.toolkit.adkit.AdFree`）：纯规则，不播广告。状态是存档里的一张表。
- `AdReward`（`sumeru.toolkit.adkit.AdReward`）：统一入口。先查次数；免广时直接发奖，否则播激励视频，完整看完才发奖。

默认规则，数值都可以配置：

| 配置 | 默认 | 含义 |
| --- | --- | --- |
| `dailyCap` | 50 | 每天广告奖励总次数。看广告和免广直领加在一起算，免不免广都一样，免广只是跳过视频 |
| `dailyTarget` | 15 | 当天完整看满几次，当天剩下的次数直接领 |
| `streakDays` | 3 | 连续几天看满，开启长期免广 |
| `passDays` | 15 | 长期免广持续几天，开启当天算第 1 天；期间每天也是 `dailyCap` 次，全部直接领 |
| `limits` | `{}` | 各广告点每天上限，如 `{hawk=4,gift=3}`；没登记的广告点只受总上限约束 |

```lua
local SaveKit=require("sumeru.toolkit.savekit")
local AdKit=require("sumeru.toolkit.adkit")
local AdFree=require("sumeru.toolkit.adkit.AdFree")
local AdReward=require("sumeru.toolkit.adkit.AdReward")

-- 存档结构：免广状态用框架给的声明
local schema={ads={free=AdFree.Schema()}}

local rules=AdFree.new({dailyCap=50,dailyTarget=15,streakDays=3,passDays=15,limits={hawk=4,gift=3}})
-- 读档后整理一次（跨天清零、旧版永久免广转成长期免广）
data.ads.free=rules:Normalize(data.ads.free)

local ads=AdReward.new({
 ad=AdKit.new({sdk=sdk,simulate=Platform.IsDesktopPlatform()}),
 rules=rules,
 state=function() return data.ads.free end,
 notice=function(text) ShowToast(text) end,
 save=function() SaveGame() end,
 onStart=function(placement) PauseGame();SetAdPlacement(placement) end, -- 开始播放
 onEnd=function() ResumeGame() end,                                      -- 播放结束（不论成败）
})

-- 广告点：只管发奖，返回提示；返回 nil 表示奖励已失效，不发也不计这个点的次数
ads:Reward("gift",function() AddItem("steel",5);return "旅商赠礼：精钢 ×5" end)
-- 只推进免广进度、没有奖励的按钮
ads:Watch("ad_free")
-- UI
local s=ads:Status()   -- free、pass、passDaysLeft、todayViews/dailyTarget、streak/streakDays、todayTotal/dailyCap、left
local left=ads:Left("gift")  -- 这个广告点今天还能领几次，已算上总上限
```

- 次数口径：完整看完的广告和免广直领各算 1 次，计入当天总次数；没看完、播放失败都不算。
- 看完广告但 `grant()` 返回 nil（例如奖励已失效）时，当天总次数照算，这个广告点的次数不算。
- 免广进度只认完整看完的广告；已免广（当天看满或长期免广中）时不再推进。
- 连续天数按本地日历算，漏掉一天就归零；长期免广期间不会断，到期后重新累计。
- 旧版存档里的 `permanent`（永久免广）读档时改成从当天起的长期免广，`freeUses` 并进当天总次数。
- 提示文案在 `AdReward.TEXTS`，`new` 时传 `texts` 覆盖其中几条即可。

## 广告位配置（上线前必查）

广告位由宿主从项目 `.project/settings.json` 的 `@runtime.ad` 读取，Lua 不写也不硬编码任何广告位 ID。

1. 用 Maker MCP `get_ad_config` 同步配置，确认 `ad.status == 1`。
2. **本地开发时**，`get_ad_config` 只把结果写进 Maker 远端工作区，不会写本地文件；而正式包从本地仓库构建，所以必须把返回的 `ad` 块原样写进本地 `.project/settings.json` 的 `@runtime` 下，并随代码一起提交：

   ```json
   "@runtime": {
       "ad": { "status": 1, "ad_spaces": [ ... ], "top_on_placements": [ ... ] }
   }
   ```

   `ad_spaces`、`top_on_placements` 照抄 `get_ad_config` 的返回值，不要自己编，也不要从别的项目复制。
3. 缺 `@runtime.ad` 时 Maker 预览仍然正常（预览走内置 FakeAd，不需要广告位），但**正式版必然提示播放失败**。所以预览和桌面 simulate 都不能证明正式广告可用，发版后要真机验证。
4. 广告开通状态或广告位变化后，重新 `get_ad_config` 并更新本地 `@runtime.ad`。

`dev/sumeru/setup.ps1`（每次同步框架时运行）会检查：项目脚本用到广告而 `settings.json` 缺 `@runtime.ad` 时给出警告。
