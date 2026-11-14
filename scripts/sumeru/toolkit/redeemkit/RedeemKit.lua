-- 兑换码，两种来源：
-- 1. 游戏内置码：码和奖品写在游戏配置里，本地判断，领过的记进游戏存档，同一个存档一个码只能领一次。不连网，Maker 真机能用。
-- 2. TapTap 礼包「无服务器兑换」：码交给 TapTap 判断（有效、用过、每人限领、过期、库存），按返回的奖品发奖。
--    Maker 真机会拦这个地址（不在网络白名单里，只能找 Maker 团队加），开通前只在电脑上能用。
-- 先认内置码，不在表里的再走 TapTap。
local Sha1=require("sumeru.toolkit.redeemkit.Sha1")

local RedeemKit={};RedeemKit.__index=RedeemKit

local HOSTS={cn="https://poster-api.xd.cn",global="https://poster-api.xd.com"}
local PATH="/api/v1.0/cdk/game/submit-simple"
local NONCE="abcdefghijklmnopqrstuvwxyz0123456789"

-- 给玩家看的提示，一句短话；游戏可用 opts.messages 按键覆盖。数字键是 TapTap 返回的错误码。
RedeemKit.Messages={
 empty="先输入兑换码",
 no_user="登录 TapTap 后才能兑换",
 closed="兑换暂未开放",
 busy="正在兑换，稍等",
 invalid="兑换码不对",
 network="网络不好，稍后再试",
 other="兑换失败（%s）",
 [100001]="兑换码不对",[100016]="兑换码不对",
 [100025]="已经领过了",[100017]="已经领过了",
 [100006]="这个码领完了",[100012]="这个码领完了",
 [100008]="兑换码过期了",
 -- 引擎（原生）遇到非 2xx 只给状态码、不给返回内容，只能按状态码认：实测码不存在是 451
 ["HTTP 451"]="兑换码不对",
}

-- 当前 TapTap 账号的用户 ID（作为 character_id，TapTap 按它判断每人限领）；未登录、本地预览返回 nil。
function RedeemKit.UserId()
 local tries={
  function() return GetUserId() end,
  function() return clientCloud.userId end,
  function() return lobby:GetMyUserId() end,
 }
 for _,try in ipairs(tries) do
  local ok,v=pcall(try)
  if ok and v~=nil then
   v=tostring(v)
   if v~="" and v~="0" then return v end
  end
 end
 return nil
end

-- 请求签名：sha1(timestamp .. nonce_str .. client_id)，小写十六进制。
function RedeemKit.Sign(timestamp,nonce,clientId) return Sha1.hex(tostring(timestamp)..nonce..clientId) end

-- 输入规整：只去掉所有空白，大小写原样（TapTap 随机生成的码是小写，后台定制码也可能混写）。
function RedeemKit.Normalize(code) return (tostring(code or ""):gsub("%s+","")) end

local function globalJson() local ok,v=pcall(function() return cjson end);return ok and v or nil end

-- opts：clientId（开发者中心「游戏服务 → 应用配置」）、region（cn/global，默认 cn）、
-- json（有 encode/decode 的编解码器，默认全局 cjson）、messages（覆盖提示）；
-- simulate=true（桌面本地开发）：没配 clientId 时不连 TapTap，每个码第一次按成功回调、发 simulateItems，
-- 同一个码再兑提示「已经领过了」，只用来走通发奖和提示；配了 clientId 就照常请求 TapTap。
-- codes：游戏内置码 {[码]={{name,number},...}}，大小写不分；redeemed：返回存档里记已领内置码的表的函数（不给只记在内存里）。
-- 测试注入：http（同运行时 http 的接口）、userId（函数）、now（秒级时间函数）、random（同 math.random）。
function RedeemKit.new(opts)
 opts=opts or {}
 local self=setmetatable({},RedeemKit)
 self.clientId=tostring(opts.clientId or "")
 self.url=(opts.host or HOSTS[opts.region or "cn"] or HOSTS.cn)..PATH
 self.json=opts.json or globalJson()
 self.http=opts.http
 self.userId=opts.userId or RedeemKit.UserId
 self.now=opts.now or os.time
 self.random=opts.random or math.random
 self.timeoutMs=opts.timeoutMs or 10000
 self.userAgent=opts.userAgent or "Mozilla/5.0"
 self.messages=setmetatable(opts.messages or {},{__index=RedeemKit.Messages})
 self.simulate=opts.simulate==true
 self.simulateItems=opts.simulateItems or {{name="钻石",number=100}}
 self.simulated={}
 self.codes={}
 for c,items in pairs(opts.codes or {}) do self.codes[RedeemKit.Normalize(c):lower()]=items end
 self.redeemed=opts.redeemed
 self.localUsed={}
 self.busy=false
 return self
end

function RedeemKit:IsBusy() return self.busy end

function RedeemKit:message_(key)
 local m=self.messages[key]
 if m then return m end
 return string.format(self.messages.other,tostring(key))
end

local function call(callback,ok,result)
 local fine,err=pcall(callback,ok,result)
 if not fine then print("[RedeemKit] 回调出错："..tostring(err)) end
end

function RedeemKit:fail_(callback,key,detail)
 call(callback,false,{code=key,message=self:message_(key),detail=detail})
end

-- 解析奖品：优先 content_obj，没有时把 content（嵌套的 JSON 字符串）再解一次。
function RedeemKit:items_(data)
 local items=data.content_obj
 if type(items)~="table" then
  local ok,c=pcall(self.json.decode,tostring(data.content or ""))
  items=ok and type(c)=="table" and c or {}
 end
 if items.name~=nil then items={items} end
 local list={}
 for _,it in ipairs(items) do
  local name=type(it)=="table" and it.name~=nil and tostring(it.name) or ""
  local n=type(it)=="table" and math.floor(tonumber(it.number or it.num) or 0) or 0
  if name~="" and n>0 then list[#list+1]={name=name,number=n} end
 end
 return list
end

-- 处理 TapTap 的返回：error 为 0 才算成功。
function RedeemKit:finish_(callback,status,body,err)
 self.busy=false
 local data
 if body and body~="" and self.json then
  local ok,v=pcall(self.json.decode,body)
  if ok and type(v)=="table" then data=v end
 end
 if not data then
  print("[RedeemKit] 兑换请求失败 status="..tostring(status).." err="..tostring(err))
  -- 有 HTTP 状态码却不是 JSON（如被拦截的 403）：带上状态码，方便玩家截图反馈
  if (tonumber(status) or 0)>=400 then return self:fail_(callback,"HTTP "..tostring(status),err) end
  return self:fail_(callback,"network",err or status)
 end
 local code=tonumber(data.error)
 if code==0 and data.success~=false then
  return call(callback,true,{activityId=data.activity_id~=nil and tostring(data.activity_id) or "",items=self:items_(data)})
 end
 local info=type(data.info)=="table" and data.info or {}
 print("[RedeemKit] 兑换失败 error="..tostring(data.error).." message="..tostring(data.message).." dev="..tostring(info.dev_message).." hint="..tostring(info.hint))
 self:fail_(callback,code or ("HTTP "..tostring(status)),data.message)
end

function RedeemKit:send_(body,done)
 local h=self.http
 if h==nil then local ok,v=pcall(function() return http end);h=ok and v or nil end
 if h==nil then return done(0,nil,"http unavailable") end
 local okPost,post=pcall(function() return HTTP_POST end)
 local ok,err=pcall(function()
  h:Create()
   :SetUrl(self.url)
   :SetMethod(okPost and post or "POST")
   :SetTimeout(self.timeoutMs)
   :AddHeader("User-Agent",self.userAgent)
   :SetContentType("application/json")
   :SetBody(body)
   :OnSuccess(function(_,res) done(res and res.statusCode or 0,res and res.dataAsString or "",nil) end)
   :OnError(function(_,status,msg) done(status or 0,nil,msg or "error") end)
   :Send()
 end)
 if not ok then done(0,nil,tostring(err)) end
end

-- 桌面模拟：不发请求，每个码第一次成功，再兑就是「已经领过了」。
function RedeemKit:simulate_(code,callback)
 if self.simulated[code] then return self:fail_(callback,100025) end
 self.simulated[code]=true
 print("[RedeemKit] 模拟兑换（没配 Client ID，不连 TapTap）："..code)
 local items={}
 for i,it in ipairs(self.simulateItems) do items[i]={name=it.name,number=it.number} end
 call(callback,true,{activityId="simulate",items=items})
end

-- 内置码：本地发奖，码记进 redeemed() 的表（游戏随后存档），同一个存档再兑就是「已经领过了」。activityId 是码本身。
function RedeemKit:local_(key,callback)
 local used=self.redeemed and self.redeemed() or self.localUsed
 if used[key] then return self:fail_(callback,100025) end
 used[key]=true
 local items={}
 for i,it in ipairs(self.codes[key]) do items[i]={name=it.name,number=it.number} end
 call(callback,true,{activityId=key,items=items})
end

-- 兑换一个码。callback(true,{activityId,items={{name,number}}}) 或 callback(false,{code,message})，只回调一次。
-- 内置码当场发奖、不发请求；码为空、没登录、上一个还没回来、没配 clientId 时当场失败，不发请求
-- （没配 clientId 时：simulate 走本地模拟；配了内置码就提示「兑换码不对」，否则「兑换暂未开放」）。
function RedeemKit:Redeem(code,callback)
 code=RedeemKit.Normalize(code)
 if code=="" then return self:fail_(callback,"empty") end
 local key=code:lower()
 if self.codes[key] then return self:local_(key,callback) end
 if self.clientId=="" or not self.json then
  if self.simulate then return self:simulate_(code,callback) end
  return self:fail_(callback,next(self.codes) and "invalid" or "closed")
 end
 if self.busy then return self:fail_(callback,"busy") end
 local uid=self.userId()
 if not uid then return self:fail_(callback,"no_user") end
 local ts=math.floor(self.now())
 local chars={}
 for i=1,5 do local k=self.random(1,#NONCE);chars[i]=NONCE:sub(k,k) end
 local nonce=table.concat(chars)
 local body=self.json.encode({client_id=self.clientId,gift_code=code,character_id=uid:sub(1,50),
  nonce_str=nonce,timestamp=ts,sign=RedeemKit.Sign(ts,nonce,self.clientId)})
 self.busy=true
 local done=false
 self:send_(body,function(status,res,err)
  if done then return end
  done=true
  self:finish_(callback,status,res,err)
 end)
end

return RedeemKit
