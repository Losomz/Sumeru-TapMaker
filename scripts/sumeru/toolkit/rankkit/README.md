# RankKit：排行榜（clientCloud 整数云变量）

`require("sumeru.toolkit.rankkit")` 把分数写进 Maker 的 `clientCloud` 整数云变量（iscores），按 key 读前几名，配上 TapTap 昵称，再查自己的名次。单机项目也能用，不需要服务器，也不走 HTTP 白名单。

- 每个榜对应一个 key，一个玩家在一个 key 下只有一个分数。
- 默认**只记历史最高**：存档在本机，重装或换手机后本地从 0 开始，直接覆盖会把云端的成绩冲掉。第一次上报先读云端已有的分数，只有更高才写。
- 读写都是异步的。所有回调只认一次，超时、迟到、重复的回调都丢掉；SDK 调用包在 `pcall` 里，出错打 `[RankKit]` 日志。
- 电脑本地预览时，引擎自带一个模拟云端：用户 ID 固定为 1001，有几个固定的假玩家，查不了昵称（显示「玩家」+ ID 后 4 位）。不开 `simulate` 用的就是它。
- `simulate=true` 时不连任何云服务，用内存里的假云端，另有 20 个「模拟玩家」，分数围绕你的分数铺开，结果固定，只给截图和自检用。

引擎文档：`engine-docs/recipes/client-cloud-score.md`（接口、限额）。

## 游戏要做的五样

1. **榜单配置**：每个榜一个 id（游戏里用）和一个云变量 key。**key 上线后不能改名**，改了等于开新榜，旧成绩全丢。
   ```lua
   -- App 初始化时
   local RankKit=require("sumeru.toolkit.rankkit")
   self.rank=RankKit.new({
    boards={
     depth={key="endless_depth"},     -- 无尽地牢最高层
     power={key="display_power"},     -- 展柜战力（历史最高）
    },
    onChange=function() self.dirty=true end, -- 榜单读完、出错时刷新界面
   })
   ```
   正式包不要开 `simulate`，也别按 `Platform.IsDesktopPlatform()` 开：TapTap PC 版也是桌面平台，PC 玩家会看到假榜（要按环境判断用 [EnvKit](../envkit/README.md) 的 `IsLocalDev()`）。截图场景里另建一个 `simulate=true` 的替换掉就行。
2. **分数函数**：每个榜写一个从存档算分数的函数，返回整数。分数要能稳定涨上去，比如最高层数、战力之和；不要用会来回跳的值。
   ```lua
   local function depth(p) return p.dungeon.depth end
   local function power(p) local n=0;for _,s in ipairs(displayed(p)) do n=n+s.atk end;return math.floor(n) end
   ```
3. **上报**：每帧调 `Update`，每秒对每个榜调一次 `Submit`。没涨的分数当场跳过，不发请求；同一个榜两次写入至少隔 `gap` 秒，期间只记最新值，所以每秒调用不会刷爆限额。启动、打完一关、换装备都会自然报上去。
   ```lua
   function App:Update(dt)
    self.rank:Update(dt)
    self.rankTimer=(self.rankTimer or 0)+dt
    if self.rankTimer>=1 then
     self.rankTimer=0
     self.rank:Submit("depth",depth(self.p))
     self.rank:Submit("power",power(self.p))
    end
   end
   ```
4. **排行页**：每个榜一个标签，打开页面和切标签时调 `Fetch`，界面按 `View` 画。
   - `status` 有四种：`idle`（还没读）、`loading`（第一次读）、`ok`、`error`（连不上或没登录）。
   - `message` 是要给玩家看的一句话：没登录、连不上、空榜。出错时点一下提示行就 `Fetch(id, true)` 重读。
   - `rows` 每行有名次、昵称、分数，`me=true` 的是自己，高亮显示。
   - 底部固定一行「我」：`me` 有值就写「第 N 名」，没有就写「未上榜」和本地的当前值。
   ```lua
   function RankPage:Show() self.app.rank:Fetch(self.tab) end
   function RankPage:Update() self.app.rank:Fetch(self.tab) end   -- 缓存过期、写入新分数后自动重读；出错后不会每帧重试
   function RankPage:Refresh()
    local v=self.app.rank:View(self.tab)
    self.status:SetVisible(v.message~=nil or v.status=="loading")
    self.status:SetText(v.status=="loading" and "读取中…" or v.message or "")
    T.tap(app,self.status,v.status=="error" and function() app.rank:Fetch(self.tab,true) end or nil)
    for i,row in ipairs(self.rows) do
     local r=v.rows[i];row:SetVisible(r~=nil)
     if r then setRow(row,r.rank,r.name,r.score,r.me) end   -- 前三名换颜色，me 高亮
    end
    self.me:SetText(v.me and ("第 "..v.me.rank.." 名") or "未上榜")
   end
   ```
5. **模拟截图与真机核对**：截图场景用 `simulate=true`，看排行页的读取中、空榜、出错、有数据四种样子和自己那行的高亮。真机要扫测试码，用**两个账号**各玩一会儿，核对：
   - 两个榜都写进去了，昵称对，自己那行高亮；
   - 名次从 0 还是从 1 数（RankKit 在你上榜时会自动对一次，榜外的名次按同样的差补）；
   - 清掉本地数据重进，榜上还是历史最高；
   - 断网时显示「排行榜暂时连不上，点一下重试」，联网后点一下能恢复。

## 接口

| 接口 | 说明 |
|---|---|
| `RankKit.new(opts)` | `boards={[id]={key, best=true}}`：`best=false` 时每次直接覆盖。可选：`count`（读前几名，默认 50）、`ttl`（榜单缓存秒数，默认 60）、`gap`（写入间隔、出错后重读间隔，默认 10 秒）、`timeout`（请求超时，默认 10 秒）、`messages`（覆盖提示语）、`onChange(id)`（某个榜的显示内容变了）、`simulate`。测试注入：`cloud`（同 `clientCloud`）、`nickname`（同 `GetUserNickname`）、`userId`（函数） |
| `kit:Submit(id, value)` | 取整后小于 1、没涨（best）或没变的不写。第一次先用 `GetUserRank` 读云端分数，更高才 `SetInt`。写失败过 `gap` 秒再试；没登录时先记着，拿到账号后补写 |
| `kit:Fetch(id, force)` | `GetRankList` → `GetUserNickname`（每批 50 个，查不到的显示「玩家」+ ID 后 4 位）→ `GetUserRank`。正在读、缓存没过期时什么都不做；出错后 `gap` 秒内不自动重读；`force` 立刻重读。写入新分数后缓存作废，下次 `Fetch` 重读 |
| `kit:View(id)` | `{status, rows={{rank, userId, name, score, me}}, me={rank, score}, message, loading}`。`loading` 表示正在后台刷新，此时 `status` 可能还是 `ok`，旧数据照常显示 |
| `kit:Update(dt)` | 每帧调：推进模拟回调、判断超时、补写分数 |
| `RankKit.UserId()` | 当前 TapTap 账号 ID（字符串），和 RedeemKit 是同一个函数 |
| `RankKit.Messages` | 默认提示语：`no_user` 登录 TapTap 后才能看排行；`error` 排行榜暂时连不上，点一下重试；`empty` 还没有人上榜 |

排行项的用户 ID 先读 `item.userId`，没有再读旧字段 `item.player`；数字和字符串 ID 都转成字符串比较。分数读 `item.iscore[key]`。

## 注意

- **分数在客户端写，可以被改。** 排行榜只适合展示，别挂高价值奖励。
- **限额**：读、写各每分钟 300 次，超了回调 `error(-429)`。一次 `Fetch` 是 3 次读（榜单、昵称、名次）。按上面的写法每秒 `Submit`，实际写入很少。
- **昵称里的字可能显示不出来。** 项目字体如果裁剪过，生僻字、表情会缺字。
- **本地预览看到的不是真榜。** 引擎自带的模拟云端只有几个固定假玩家，没有昵称；要扫测试码进游戏看真实的榜。
