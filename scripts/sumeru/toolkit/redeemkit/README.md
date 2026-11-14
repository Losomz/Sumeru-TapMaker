# RedeemKit：兑换码（TapTap 礼包 · 无服务器兑换）

`require("sumeru.toolkit.redeemkit")` 接的是 TapTap 礼包系统的「无服务器兑换」接口：游戏把玩家输入的码交给 TapTap，按返回的奖品发奖。

**分工**
- **TapTap 后台**：存码；校验码是否有效、有没有用过、有没有过期；每人限领、库存；数据查看、导出 CSV。
- **游戏**：提供输入框；调接口；按奖品名发奖。
- 游戏里不存码，不记谁领过，也不写死奖品。加活动、换奖品、补码都在 TapTap 后台做，**不用更新游戏**。

官方文档：developer.taptap.cn/docs/sdk/tds-gift/no-server-guide（接口）、…/tds-gift/guide（参数与错误码）。

## 游戏要做的四样

1. **配置**：项目里写一个配置文件，填上 Client ID。Client ID 在开发者中心「游戏服务 → 应用配置」，本来就是给客户端用的，可以提交。
   ```lua
   -- scripts/game/config/Redeem.lua
   return {clientId="<Client ID>"}
   ```
2. **入口**：在设置页放一个 `TextField` 输入框和一个「兑换」按钮。请求期间按钮显示「兑换中…」，兑换成功后清空输入框。
3. **发奖函数**：把 TapTap 返回的奖品名对应到游戏里的东西。
   - 奖品名直接用游戏里的显示名，比如「钻石」「金币」「秘银」；
   - 对不上的名字跳过并打日志；
   - 返回一行给玩家看的文字。
4. **数据上报（可选）**：兑换成功时报一条事件，记下活动 ID 和奖品，方便看各活动领了多少。

```lua
local RedeemKit=require("sumeru.toolkit.redeemkit")
local C=require("game.config.Redeem")
-- 电脑上没有 TapTap 登录：给个固定测试 ID 才能拿真码试兑；没填 Client ID 时 simulate 走本地模拟，看发奖和提示
local desktop=Platform.IsDesktopPlatform()
local kit=RedeemKit.new({clientId=C.clientId,json=cjson,simulate=desktop,simulateItems=C.simulate,
 userId=desktop and function() return RedeemKit.UserId() or "desktop-test" end or nil})

function App:Redeem(code,onDone)
 kit:Redeem(code,function(ok,res)
  if ok then
   local text=Redeem.Grant(self.p,res.items)   -- 游戏自己按名字发奖
   self:Save();self:Notice("兑换成功："..text)
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
| `RedeemKit.new(opts)` | `clientId` 必填。`region`：`cn`（默认）或 `global`，两边的礼包数据不互通。`json`：编解码器，默认全局 `cjson`。`messages`：按键覆盖提示语。`simulate=true`（桌面本地开发）：没填 `clientId` 时不连 TapTap，每个码第一次按成功回调、发 `simulateItems`（默认钻石 ×100），同一个码再兑提示「已经领过了」；填了 `clientId` 就照常请求。测试时可以注入 `http`、`userId`、`now`、`random` |
| `kit:Redeem(code, callback)` | 输入只去掉空白，大小写原样提交（TapTap 随机码是小写）。成功回调 `callback(true, {activityId, items={{name, number}}})`，失败回调 `callback(false, {code, message})`。每次只回调一次 |
| `kit:IsBusy()` | 上一个请求还没返回 |
| `RedeemKit.UserId()` | 当前 TapTap 账号 ID，依次尝试 `GetUserId()`、`clientCloud.userId`、`lobby:GetMyUserId()`。拿不到返回 nil |
| `RedeemKit.Sign(ts, nonce, clientId)` | `sha1(ts .. nonce .. clientId)`，结果是小写十六进制 |
| `RedeemKit.Messages` | 默认提示语，见下表 |

以下几种情况当场失败，不发请求：

| 情况 | 失败原因 `code` |
|---|---|
| 码为空 | `empty` |
| 没配 Client ID | `closed` |
| 上一个请求还没返回 | `busy` |
| 拿不到账号 ID | `no_user` |

账号 ID 会作为 `character_id` 发给 TapTap，「每人限领」就是按它判断的。

**默认提示语**

| `code` | 提示 |
|---|---|
| 100001 / 100016 | 兑换码不对 |
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

- **先用真机验证能不能连上。** Maker 对外部网络请求有限制，能不能访问 `poster-api.xd.cn` 要真机实测。
  - 被拦截时会提示「兑换失败（HTTP 403）」或「网络不好」，日志里能看到状态码；
  - 拦截的话，联系 Maker 团队给这个地址加白名单。
- **安全性。** 兑换结果直接返回到客户端，可能被截取伪造，官方也说明这种方式的安全系数比有服务器的方式低。适合补偿和活动，不适合发高价值奖励。
- **手机时间要准。** 时间戳只有一分钟有效期，手机时间偏差太大时，TapTap 会拒绝请求。
- **本地预览拿不到账号 ID。** 提示「登录 TapTap 后才能兑换」是正常的，要扫测试码进游戏试。
