# TickKit：更新调度（时间线、倍速与暂停）

`require("sumeru.toolkit.tickkit")` 返回更新调度 System。需要按帧推进的对象交给一条**时间线**，倍速、暂停和固定步长都由时间线统一管理，业务不再各自维护积攒时间。框架不引用业务模块，项目在架构上注册一次，入口每帧调用一次 `Update`。

```lua
local TickKit=require("sumeru.toolkit.tickkit")
local arch=Sumeru.Architecture.MakeArchitecture("my-game")
arch:RegisterSystem("TickKit",TickKit.new())

local ticks=arch:GetSystem("TickKit")

-- 战斗模拟：固定 1/30 秒一步，单帧真实时间最多算 0.2 秒。
local battle=ticks:Timeline("battle",{step=1/30,maxDelta=.2})
battle:Add(function(dt,line) world:Step(dt) end)
battle:Add(enemyDirector,10)       -- 带 :Tick(dt,line) 的表，priority 大的后执行

battle:SetScale(2)                 -- 2 倍速
battle:SetHold("menu",menuOpen)    -- 按原因暂停：每帧按状态同步即可
battle:Reset()                     -- 读档、换关后丢弃积攒时间

-- 入口每帧调用一次，按创建顺序推进全部时间线。
function HandleUpdate(eventType,eventData) ticks:Update(eventData["TimeStep"]:GetFloat()) end
```

## 时间线

`ticks:Timeline(name,options)` 按名称取或建时间线，选项只在首次创建时生效：

| 字段 | 说明 |
|---|---|
| `step` | 固定步长（秒）。设了就按积攒时间一步步推进；不设则每帧推进一次，dt 为缩放后的帧时间 |
| `maxDelta` | 单帧真实时间上限（秒，缺省 0.25），先截断再乘倍速，卡顿后不会一次补跑太多步 |
| `maxSteps` | 单帧最多执行的固定步数（缺省不限），超出时丢弃剩余积攒时间 |

| 接口 | 说明 |
|---|---|
| `Add(target,priority?)` / `Remove(target)` / `Clear()` | 成员是函数 `fn(dt,line)` 或带 `:Tick(dt,line)` 的表；按 priority 从小到大执行，同级按加入顺序；重复加入会被忽略 |
| `SetScale(s)` / `Scale()` | 倍速，不小于 0；只影响之后积攒时间的速度 |
| `Hold(reason)` / `Release(reason)` / `SetHold(reason,on)` / `Paused()` | 按原因暂停，全部原因解除才恢复；暂停时丢弃积攒时间，恢复后不补帧 |
| `Reset()` | 丢弃积攒时间 |
| `Interrupt(drop?)` | 只在成员里调用：当前这一步照常跑完，本帧不再执行后面的步数；`drop=true` 时同时丢弃剩余积攒时间 |
| `Time()` / `Delta()` | 累计推进的缩放后时间；上一帧推进的缩放后时间（暂停或没攒够一步时为 0） |
| `Stats()` | 成员数、倍速、是否暂停、累计时间与步数 |

## TickKit（System）

- `Timeline(name,options)`：取或建时间线，新建的排在已有时间线之后推进。
- `Get(name)`、`Release(name)`：查询；注销并移除全部成员。
- `Update(dt)`：入口每帧调用一次，按创建顺序推进全部时间线。
- `Stats()`：按创建顺序返回每条时间线的统计行，供调试面板低频读取。

## 约定

- 一个架构只注册一个 TickKit，入口只调用一次 `Update`；不要在成员里再调用 `Update` 或 `Advance`。
- 同一组需要一起变速、一起暂停的对象放进同一条时间线。界面动画、提示、音频等不该跟着变速的，不要放进战斗时间线。
- 成员可以在执行中途增删：新加入的从下一步开始执行，移除的立即跳过。
- 需要在某个事件后立刻停下处理（例如弹出选择界面、阶段切换），在成员里调用 `Interrupt`；需要持续停住的，用 `Hold`。
- 表现层要跟着变速时，读取时间线的 `Scale()` 乘到自己的帧时间上，暂停判断仍由表现层自己负责。
- 时间线只管推进时机，不保存状态；存档里不要放时间线对象。
