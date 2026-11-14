# RedeemKit：兑换码（游戏内置码 / TapTap 礼包）

`require("sumeru.toolkit.redeemkit")` 支持两种码，先认内置码，不在表里的再交给 TapTap：

| | 游戏内置码 | TapTap 礼包「无服务器兑换」 |
|---|---|---|
| 码和奖品放哪 | 游戏配置里 | TapTap 后台 |
| 谁判断领没领过 | 游戏存档，同一个存档一个码只能领一次 | TapTap，按账号每人限领、库存、过期 |
| 加码、换奖品 | 要更新游戏 | 后台改，不用更新游戏 |
| Maker 真机 | **能用**（不连网） | **用不了**：地址不在 Maker 网络白名单里，见「注意」 |

**现在 Maker 游戏用内置码。** TapTap 礼包的接入代码留着：等 Maker 团队给地址加了白名单，填上 Client ID 就能用。

官方文档：developer.taptap.cn/docs/sdk/tds-gift/no-server-guide（接口）、…/tds-gift/guide（参数与错误码）。

## 游戏要做的五样

1. **配置**：项目里写一个配置文件，列出内置码和奖品。Client ID 先空着（开了白名单再填，在开发者中心「游戏服务 → 应用配置」，本来就是给客户端用的，可以提交）。
   ```lua
   -- scripts/game/config/Redeem.lua
   local codes={
    ["<补偿码：随机串>"]={{name="钻石",number=100},{name="秘银",number=5}},   -- 奖品名写游戏里的显示名
    ["<福利码：游戏名缩写+版本，如 laojie021>"]={{name="钻石",number=50}},    -- 更新公告里人人能领
   }
   return {clientId="",codes=codes}
   ```
   - 领没领过按存档记，不按人。给玩家的回复都是公开的，一人一个码也拦不住别人看到后拿去用，所以**补偿就用一个共用码**（随机串，10 位以上），要补偿的人都发这一个。
   - 更新公告里可以放一个人人能领的福利码，用好记的词加版本号，奖励比补偿码少。
   - 码写在包里，只适合补偿和小活动，不适合高价值奖励。
   - 发出去的码别删：删了以后玩家再兑会提示「兑换码不对」。
   - 给玩家回复、@ 玩家发码的做法见 `dev/sumeru/publish/论坛公告.md`「回复玩家、发补偿」。
2. **存档字段**：存档里加一张表记领过的内置码，比如 SaveKit schema 里 `redeemed=map(false)`。
3. **入口**：在设置页放一个 `TextField` 输入框和一个「兑换」按钮。请求期间按钮显示「兑换中…」，兑换成功后清空输入框。
4. **发奖函数**：把奖品名对应到游戏里的东西。
   - 奖品名直接用游戏里的显示名，比如「钻石」「金币」「秘银」；
   - 对不上的名字跳过并打日志；
   - 返回一行给玩家看的文字。
5. **数据上报（可选）**：兑换成功时报一条事件，记下活动 ID（内置码就是码本身）和奖品，方便看谁领了、各活动领了多少。

```lua
local RedeemKit=require("sumeru.toolkit.redeemkit")
local C=require("game.config.Redeem")
-- 内置码领过的记在存档 p.redeemed；电脑上没有 TapTap 登录，给个固定测试 ID 才能拿 TapTap 的码试兑
local desktop=Platform.IsDesktopPlatform()
local kit=RedeemKit.new({clientId=C.clientId,json=cjson,codes=C.codes,redeemed=function() return app.p.redeemed end,   -- app.p：游戏的存档数据
 userId=desktop and function() return RedeemKit.UserId() or "desktop-test" end or nil})

function App:Redeem(code,onDone)
 kit:Redeem(code,function(ok,res)
  if ok then
   local text=Redeem.Grant(self.p,res.items)   -- 游戏自己按名字发奖
   self:Save();self:Notice("兑换成功："..text)   -- 存档，内置码的领取记录也一起存上
  else
   self:Notice(res.message)                     -- 已经翻成一句短话
  end
  if onDone then onDone(ok) end
 end)
end
```

## 接口

| 接口 | 说明 |
|---|---|
| `RedeemKit.new(opts)` | `codes`：内置码 `{[码]={{name, number}, ...}}`，大小写不分。`redeemed`：返回存档里记已领内置码那张表的函数（不给只记在内存里，重启就忘）。`clientId`：TapTap 礼包的 Client ID，空着就不连 TapTap。`region`：`cn`（默认）或 `global`，两边的礼包数据不互通。`json`：编解码器，默认全局 `cjson`。`messages`：按键覆盖提示语。`simulate=true`（桌面本地开发）：没填 `clientId` 时不连 TapTap，每个码第一次按成功回调、发 `simulateItems`（默认钻石 ×100），同一个码再兑提示「已经领过了」；填了 `clientId` 就照常请求。测试时可以注入 `http`、`userId`、`now`、`random` |
| `kit:Redeem(code, callback)` | 输入只去掉空白。先查内置码（不分大小写），命中就当场发奖、把码记进 `redeemed()` 的表，`activityId` 是码本身；没命中再交给 TapTap，大小写原样提交（TapTap 随机码是小写）。成功回调 `callback(true, {activityId, items={{name, number}}})`，失败回调 `callback(false, {code, message})`。每次只回调一次 |
| `kit:IsBusy()` | 上一个请求还没返回 |
| `RedeemKit.UserId()` | 当前 TapTap 账号 ID，依次尝试 `GetUserId()`、`clientCloud.userId`、`lobby:GetMyUserId()`。拿不到返回 nil |
| `RedeemKit.Sign(ts, nonce, clientId)` | `sha1(ts .. nonce .. clientId)`，结果是小写十六进制 |
| `RedeemKit.Messages` | 默认提示语，见下表 |

以下几种情况当场失败，不发请求：

| 情况 | 失败原因 `code` |
|---|---|
| 码为空 | `empty` |
| 不是内置码，也没配 Client ID | 配了内置码时 `invalid`（兑换码不对），否则 `closed` |
| 内置码这个存档领过了 | `100025`（已经领过了） |
| 上一个请求还没返回 | `busy` |
| 拿不到账号 ID | `no_user` |

账号 ID 会作为 `character_id` 发给 TapTap，「每人限领」就是按它判断的。

**默认提示语**

| `code` | 提示 |
|---|---|
| `invalid` / 100001 / 100016 | 兑换码不对 |
| 100017 / 100025 | 已经领过了 |
| 100006 / 100012 | 这个码领完了 |
| 100008 | 兑换码过期了 |
| `HTTP 451` | 兑换码不对（码不存在时 TapTap 回 451） |
| `network` | 网络不好，稍后再试 |
| 其他错误码，或 `HTTP 403` 这类 | 兑换失败（原因） |

引擎（原生）遇到非 2xx 只把状态码交给 `OnError`，TapTap 的错误 JSON 拿不到，所以 TapTap 用 4xx 回的错误只能按状态码认。已实测：码不存在 451、签名错 422；其他错误先显示「兑换失败（HTTP 状态码）」，测到新的就往 `Messages` 里补。

每次失败日志里都会打一行 `[RedeemKit] 兑换失败 error=… message=… dev=… hint=…`，排查先看这一行。

## 在 TapTap 后台建礼包活动

1. 打开开发者中心 → 你的游戏 → 运营工具 → 礼包，新建活动。兑换方式选**无服务器兑换**，选错会报 100018。
2. 选码的类型：
   - **通兑码**：多人共用一个码，每人限领一次。适合全员活动，可以直接贴在公告里。
   - **唯一码**：一个码只能被用一次。适合补偿指定的玩家，要私下发给本人。公开贴出去会被别人先用掉。
3. 填奖品：**奖品名必须和游戏里的显示名完全一致**，数量填整数。名字对不上的奖品，游戏会跳过不发。
4. 打开活动列表里的上架开关。不上架的话，码兑换不了（Unity 下会返回 HTTP 422）。
5. 码在「礼包活动 → 数据 → 导出」里导出 CSV，用到哪些码也在这里看。

## 注意

- **Maker 真机连不上 TapTap 礼包（已实测，2026-11-14）。** 真机日志：`HttpClient:Send blocked: URL is not in the whitelist`，玩家看到「网络不好」。
  - Maker 运行时只放行白名单里的地址（engine-docs `recipes/http.md`：整串匹配，加白名单要联系 TapTap 制造团队）。开发者没有自助入口，TapTap CLI、Maker CLI、项目配置里都没有。
  - 平台内置的白名单只有官方服务，比如 GameAlgo 数据上报的 `game-algo-sdk.dictapis.cn` / `game-algo-admin.dictapis.cn`（按域名放行），所以数据上报能用、礼包不能。
  - 要加的地址是 `https://poster-api.xd.cn/api/v1.0/cdk/game/submit-simple`（海外 `poster-api.xd.com`）。加上之前用内置码，Client ID 空着，不然打错码也只会提示「网络不好」。
- **安全性。** 兑换结果直接返回到客户端，可能被截取伪造，官方也说明这种方式的安全系数比有服务器的方式低。适合补偿和活动，不适合发高价值奖励。
- **手机时间要准。** 时间戳只有一分钟有效期，手机时间偏差太大时，TapTap 会拒绝请求。
- **本地预览拿不到账号 ID。** 提示「登录 TapTap 后才能兑换」是正常的，要扫测试码进游戏试。
