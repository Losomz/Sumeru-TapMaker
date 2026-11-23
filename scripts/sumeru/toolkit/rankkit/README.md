# RankKit：排行榜（clientCloud 整数云变量）

`require("sumeru.toolkit.rankkit")` 把分数写进 Maker 的 `clientCloud` 整数云变量（iscores），按 key 读前几名，配上 TapTap 昵称，再查自己的名次。单机项目也能用，不需要服务器，也不走 HTTP 白名单。

- 每个榜对应一个 key，一个玩家在一个 key 下只有一个分数。
- 默认**只记历史最高**：存档在本机，重装或换手机后本地从 0 开始，直接覆盖会把云端的成绩冲掉。第一次上报先读云端已有的分数，只有更高才写。
- 可选**日 / 周 / 月榜**（`periods`）：比的是同一个数，本期上报过的人才上榜；每一期是一个带日期后缀的 key，到点（默认北京时间）自动换新一期。总榜照常。
- 可选**附加资料**（`profile`）：每人一份小表（头像、展出的装备之类），内容变了才写，读榜时跟着每一行带回来。
- 读写都是异步的。所有回调只认一次，超时、迟到、重复的回调都丢掉；SDK 调用包在 `pcall` 里，出错打 `[RankKit]` 日志。
- 电脑本地预览时，引擎自带一个模拟云端：用户 ID 固定为 1001，有几个固定的假玩家，查不了昵称（显示「玩家」+ ID 后 4 位）。不开 `simulate` 用的就是它。
- `simulate=true` 时不连任何云服务，用内存里的假云端，另有 20 个「模拟玩家」，分数围绕你的分数铺开，结果固定，只给截图和自检用。

引擎文档：`engine-docs/recipes/client-cloud-score.md`（接口、限额）。

## 游戏要做的六样

1. **榜单配置**：每个榜一个 id（游戏里用）和一个云变量 key。**key 上线后不能改名**，改了等于开新榜，旧成绩全丢。要日周月榜就加 `periods`。
   ```lua
   -- App 初始化时
   local RankKit=require("sumeru.toolkit.rankkit")
   self.rank=RankKit.new({
    boards={
     depth={key="endless_depth",periods=RankKit.Periods},   -- 无尽地牢最高层，另有日 / 周 / 月榜
     power={key="display_power",periods=RankKit.Periods},   -- 展柜战力
    },
    profile={key="rank_profile",get=function() return profile(self.p) end},   -- 可选，见第 5 条
    onChange=function() self.dirty=true end, -- 榜单读完、出错、换期、查到自己昵称时刷新界面
   })
   ```
   正式包不要开 `simulate`，也别按 `Platform.IsDesktopPlatform()` 开：TapTap PC 版也是桌面平台，PC 玩家会看到假榜（要按环境判断用 [EnvKit](../envkit/README.md) 的 `IsDev()`）。截图场景里另建一个 `simulate=true` 的替换掉就行。
2. **分数函数**：每个榜写一个从存档算分数的函数，返回整数。分数要能稳定涨上去，比如最高层数、战力之和；不要用会来回跳的值。
   ```lua
   local function depth(p) return p.dungeon.depth end
   local function power(p) local n=0;for _,s in ipairs(displayed(p)) do n=n+s.atk end;return math.floor(n) end
   ```
3. **上报**：每帧调 `Update`，每秒对每个榜调一次 `Submit`。`Submit` 同时报总榜和这个榜的每个周期。没涨的分数当场跳过，不发请求；同一个子榜两次写入至少隔 `gap` 秒，期间只记最新值，所以每秒调用不会刷爆限额。启动、打完一关、换装备都会自然报上去；换期后的第一次 `Submit` 就把当前值写进新一期。
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
4. **排行页**：每个榜一个标签；开了周期的，下面再一排「日榜 / 周榜 / 月榜 / 总榜」。打开页面和切标签时调 `Fetch(id, nil, period)`，界面按 `View(id, period)` 画（`period` 为 `"day"`/`"week"`/`"month"`，nil 或 `"all"` 是总榜）。
   - `status` 有四种：`idle`（还没读）、`loading`（第一次读）、`ok`、`error`（连不上或没登录）。
   - `message` 是要给玩家看的一句话：没登录、连不上、空榜。出错时点一下提示行就 `Fetch(id, true, period)` 重读。
   - `rows` 每行有名次、昵称、分数、附加资料，`me=true` 的是自己，高亮显示。
   - 底部固定一行「我」：`myName` 是自己的 TapTap 昵称（还没查到时为 nil）；`me` 有值就写「第 N 名」，没有就写「未上榜」和本地的当前值。
   - 说明行写清换榜时间（「每天 0 点换榜」「每周一 0 点换榜」「每月 1 日换榜」「记历史最高」）。
   ```lua
   function RankPage:Show() self.app.rank:Fetch(self.tab,nil,self.period) end
   function RankPage:Update() self.app.rank:Fetch(self.tab,nil,self.period) end   -- 缓存过期、写入新分数、换期后自动重读；出错后不会每帧重试
   function RankPage:Refresh()
    local v=self.app.rank:View(self.tab,self.period)
    self.status:SetVisible(v.message~=nil or v.status=="loading")
    self.status:SetText(v.status=="loading" and "读取中…" or v.message or "")
    T.tap(app,self.status,v.status=="error" and function() app.rank:Fetch(self.tab,true,self.period) end or nil)
    for i,row in ipairs(self.rows) do
     local r=v.rows[i];row:SetVisible(r~=nil)
     if r then setRow(row,r.rank,r.name,r.score,r.me,r.profile) end   -- 前三名换颜色，me 高亮
    end
    self.myName:SetText(v.myName or "我")
    self.me:SetText(v.me and ("第 "..v.me.rank.." 名") or "未上榜")
   end
   ```
5. **附加资料（可选）**：`profile.get()` 返回一张小表，只放画榜要用的东西（头像 id、前几件装备的图标字段和等级），别塞整份存档。RankKit 每秒比一次内容，变了才 `clientCloud:Set` 写（受 `gap` 限频，没登录先记着）；读榜时 `GetRankList` 带上这个 key，每行的 `row.profile` 就是那张表（别人的版本可能比你旧或新，字段要逐个校验，认不出的按默认画）。自己那行建议直接用本地的 `get()`，不等云端回写。**key 上线后不能改名。**
   ```lua
   local function profile(p) return {a=p.avatar,g=topGear(p,3),n=#displayed(p)} end
   ```
6. **模拟截图与真机核对**：截图场景用 `simulate=true`（附加资料用 `simProfile(i)` 给模拟玩家造），看排行页的读取中、空榜、出错、有数据四种样子和自己那行的高亮。真机要扫测试码，用**两个账号**各玩一会儿，核对：
   - 榜上和「我」那行都是 **TapTap 真昵称**，不是「玩家」+ ID 后 4 位（全员都是后者说明昵称整条没取到，按下面「昵称排查」看日志）；
   - 每个榜的总榜和日 / 周 / 月榜都写进去了，自己那行高亮；
   - 一个账号换了附加资料（头像、装备），另一个账号过一会儿重读能看到；
   - 名次从 0 还是从 1 数（RankKit 在你上榜时会自动对一次，榜外的名次按同样的差补）；
   - 清掉本地数据重进，总榜上还是历史最高；
   - 断网时显示「排行榜暂时连不上，点一下重试」，联网后点一下能恢复。

## 日 / 周 / 月榜

- 每期的 key（`RankKit.PeriodKey(key, period, now, tz)`）：日 `<key>_d20261117`，周 `<key>_w<周一的日期>`（如 `_w20261116`），月 `<key>_m202611`；总榜就是 `<key>`，所以给老榜加周期不会丢旧成绩。
- 换期按 `tz` 时区（默认 8，北京时间）的 0 点、周一 0 点、每月 1 日 0 点算，用的是本机时钟。`Update` 每秒检查一次，到点把这个子榜清空（已写、待写、榜单、名次），触发 `onChange`，之后的 `Submit` 写进新一期；换期前发出、换期后才回来的回调一律丢掉。
- 每期也是「本期最高」（`best`）：新一期第一次上报会先读云端，本期已经写过更高的就不写。
- 旧期的 key 留在云端没人读，不用清。**周期 key 的格式上线后不能改。**

## 昵称排查

- 取昵称的接口按顺序试：注入的 `nickname` → 全局 `GetUserNickname`（函数或可调用对象）→ `lobby:GetUserNickname`。每批 50 个 ID，超时 `nameTimeout`（默认 15 秒）；整批失败拆成每批 10 个再试一次。
- 用户 ID 一律过 `RankKit.IdKey` 转成整数字符串再比较：引擎回来的 ID 可能是整数、浮点或字符串，浮点直接 `tostring` 会变成 `1.2e+15`，对不上号。回包是数组或 `{[ID]=昵称}` 都认，昵称字段认 `nickname / nickName / name`，ID 字段认 `userId / user_id / id`。按 ID 一个都没对上、但回来的条数正好相等时按顺序对位。
- 每次配昵称打**一行**日志，真机上靠它查原因（让玩家在游戏里提交一条反馈就能拉到）：
  ```
  [RankKit] 昵称：GetUserNickname 问 21 个，回 21 个，对上 21 个
  [RankKit] 昵称：GetUserNickname 问 21 个，回 21 个，对上 21 个（ID 对不上，按顺序对位）
  [RankKit] 昵称：GetUserNickname 问 21 个，回 0 个，对上 0 个，失败 -1/timeout；第一条回包 …，第一行 ID …
  [RankKit] 昵称：找不到 GetUserNickname / lobby:GetUserNickname，显示「玩家」+ ID 后 4 位
  ```
  「回 N 个、对上 0 个」看后面附的第一条回包字段，「失败」看错误码，「找不到」说明这个运行环境没有昵称接口。

## 接口

| 接口 | 说明 |
|---|---|
| `RankKit.new(opts)` | `boards={[id]={key, best=true, periods}}`：`best=false` 时每次直接覆盖；`periods` 为 `RankKit.Periods` 或其中几个。可选：`count`（读前几名，默认 50）、`ttl`（榜单缓存秒数，默认 60）、`gap`（写入间隔、出错后重读间隔，默认 10 秒）、`timeout`（请求超时，默认 10 秒）、`nameTimeout`（查昵称超时，默认 15 秒）、`tz`（换期时区，默认 8）、`messages`（覆盖提示语）、`onChange(id, period)`（某个榜某一期的显示内容变了）、`profile={key, get}`、`json`（解附加资料用，默认全局 `cjson`）、`simulate`、`simProfile(i)`。测试注入：`cloud`（同 `clientCloud`）、`nickname`（同 `GetUserNickname`）、`userId`（函数）、`now`（函数，返回 `os.time` 秒数） |
| `kit:Submit(id, value)` | 报给总榜和每个周期。取整后小于 1、没涨（best）或没变的不写。每个子榜第一次先用 `GetUserRank` 读云端分数，更高才 `SetInt`。写失败过 `gap` 秒再试；没登录时先记着，拿到账号后补写 |
| `kit:Fetch(id, force, period)` | `GetRankList`（带附加资料 key）→ 配昵称（见「昵称排查」）→ `GetUserRank`；顺带查一次自己的昵称。正在读、缓存没过期时什么都不做；出错后 `gap` 秒内不自动重读；`force` 立刻重读。写入新分数、换期后缓存作废，下次 `Fetch` 重读 |
| `kit:View(id, period)` | `{status, rows={{rank, userId, name, named, score, me, profile}}, me={rank, score}, message, loading, myName}`。`loading` 表示正在后台刷新，此时 `status` 可能还是 `ok`，旧数据照常显示；`named=false` 的行是「玩家」+ ID 后 4 位的兜底名 |
| `kit:Update(dt)` | 每帧调：推进模拟回调、判断超时、换期、补写分数和附加资料 |
| `RankKit.UserId()` | 当前 TapTap 账号 ID（整数字符串）；依次试 `GetUserId()`、`clientCloud.userId`、`lobby:GetMyUserId()`，未登录、本地预览为 nil |
| `RankKit.IdKey(v)` | 用户 ID 统一成整数字符串（浮点、数字字符串都转） |
| `RankKit.PeriodKey(key, period, now, tz)` | 某一期的云变量名，见「日 / 周 / 月榜」 |
| `RankKit.Periods` | `{"day","week","month"}` |
| `RankKit.Messages` | 默认提示语：`no_user` 登录 TapTap 后才能看排行；`error` 排行榜暂时连不上，点一下重试；`empty` 还没有人上榜 |

排行项的用户 ID 先读 `item.userId`，没有再读旧字段 `item.player`；分数读 `item.iscore[key]`，附加资料读 `item.score[profile.key]`（是字符串就按 JSON 解一次）。

## 注意

- **分数和附加资料都在客户端写，可以被改。** 排行榜只适合展示，别挂高价值奖励；画附加资料前逐个字段校验。
- **限额**：读、写各每分钟 300 次，超了回调 `error(-429)`。一次 `Fetch` 约 3 次读（榜单、昵称、名次；昵称整批失败时多几次，自己的昵称另查一次）。写入：每个子榜受 `gap` 限频，2 个榜 × 4 期再加附加资料，每秒 `Submit` 的写法实际写入很少。
- **昵称里的字可能显示不出来。** 项目字体如果裁剪过，生僻字、表情会缺字。
- **本地预览看到的不是真榜。** 引擎自带的模拟云端只有几个固定假玩家，没有昵称；要扫测试码进游戏看真实的榜和昵称。
