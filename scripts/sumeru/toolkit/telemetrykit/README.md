# TelemetryKit：数据后台固定上报

`require("sumeru.toolkit.telemetrykit")`。接 GameAlgo 数据后台：事件名、字段、看板都由框架定死，各游戏的后台长得一样，游戏只能填几个值。

SDK 用项目里官方原样的 `scripts/sdk/GameAlgo.lua`（2.1.5-lua 起，里程碑在拿到后台上下文前后都由 SDK 去重）。SDK 没加载上、出错、网络不通时，这里只是空操作，不影响游戏。

## 什么固定、什么能填

| | 框架定死 | 游戏能填 |
|---|---|---|
| 概览、留存 | 标准块，原样 | 无 |
| 广告收入 | 收入、LTV 标准块；`ad_view` 由 AdKit 在广告入口自动报 | 调广告时传广告位 key |
| 启动 | `boot_begin`、`boot_ready{sec,retries,manual}`、`boot_fail`、`boot_retry` | 无 |
| 新用户流程 | 里程碑漏斗，只有 `new_user` / `global` 两类 | 节点名（中文） |
| 玩法 | `level_start` / `level_end`；字段 `level_attempt_id`、`level_id`、`level_no`、`mode`、`level_name`、`result`（只有 win / lose / quit）；玩法页三张表：每日玩法次数、区间成败（按玩法）、各关成败 | `mode`、`level_name` 的值；`level_end` 最多 3 个额外字段，先在 `Init` 和 `game.json` 里声明，每个配一张图 |
| 自定义事件 | 不开放 | 无 |

没声明的字段一律丢掉；`result` 不合法、缺 `level_attempt_id` / `level_id` / `mode` 的整条不报。测试环境（`isDebug`）会打一行日志说丢了什么。

## 接入

```lua
local TelemetryKit=require("sumeru.toolkit.telemetrykit")
local Env=require("sumeru.toolkit.envkit")

-- 启动时最先调（官方要求在存档、界面、广告之前）
TelemetryKit.Init({
 baseUrl="https://game-algo-sdk.dictapis.cn",
 gameKey="ga_live_…",            -- 客户端标识，可以提交；管理 Key 不进仓库
 appVersion="1.0.8",              -- 这次出包的版本号
 ads={rest="gap_…",sell="gap_…"}, -- 广告位 key → 后台登记的 ID（dev/gamealgo/ad-placements.yaml）
 extraFields={grade="string"},     -- 可选，最多 3 个：string / number / boolean
 isDebug=Env.IsDev(),              -- 测试环境的事件不进正式报表
})

-- 启动：用 BootKit 的直接接 onEvent；不用 BootKit 的自己在开始启动、第一页显示出来时各调一次
BootKit.new({...,onEvent=TelemetryKit.Boot})
TelemetryKit.Boot("begin");TelemetryKit.Boot("ready",{sec=2.3})

-- 一关：开始和结束用同一个 level_attempt_id
local id=TelemetryKit.AttemptId("forge")   -- 游戏自己有稳定 ID（存档里的）就用自己的
TelemetryKit.LevelStart({level_attempt_id=id,level_id="sword",level_no=3,mode="亲手打铁",level_name="长剑"})
TelemetryKit.LevelEnd({level_attempt_id=id,level_id="sword",level_no=3,mode="亲手打铁",level_name="长剑",result="win",grade="A"})

-- 里程碑：节点名和 game.json 里一致；同一次启动报过的不再报
TelemetryKit.Milestone("new_user","首次开炉")
```

广告不用在这里调：`AdKit:ShowRewardVideo(done,key)` / `AdReward:Reward(key,grant)` 传了广告位 key，AdKit 自己报 `ad_view`（见 [AdKit](../adkit/README.md)）。

## 接口

| 接口 | 说明 |
|---|---|
| `Init(cfg)` | 起 SDK，返回成功没有。`cfg` 见上 |
| `Ready()` | SDK 起来了没有 |
| `LevelStart(p)` / `LevelEnd(p)` | 一关开始、结束；返回报出去没有 |
| `Milestone(kind,point)` | `kind` 只有 `new_user` / `global` |
| `Boot(name,data)` | `begin` / `ready` 每次启动各一次；`fail`、`retry` 每次都报；`auto_retry` 不报 |
| `AttemptId(prefix)` | 生成一次尝试的 ID |
| `UseSdk(fake,cfg)` | 测试用：换成假 SDK（记下每条上报），`cfg` 同 `Init`；传 nil 换回没初始化 |
| `ShowRewardVideoAd(key,cb)` / `AdClosed(key,result)` / `AdId(key)` | AdKit 用，游戏不用直接调 |

## 看板和事件词典

模板和生成脚本在 [`dev/sumeru/gamealgo/`](../../../../dev/sumeru/gamealgo/README.md)：项目写 `dev/gamealgo/game.json`，跑 `make-pack.js` 生成 `report-pack.json` 和 `events.yaml`，再用 gamealgo CLI 提交。
