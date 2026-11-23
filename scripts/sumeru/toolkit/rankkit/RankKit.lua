-- 排行榜：分数写进 clientCloud 的整数云变量（iscores），按 key 读榜、配上 TapTap 昵称、查自己的名次。
-- 每个榜一个 key；默认只记历史最高（存档在本机，重装后本地从 0 开始，不能把云端的成绩覆盖掉）。
-- 可选日 / 周 / 月榜（periods）：每一期是一个带日期后缀的 key，到点自动换新一期；可选附加资料（profile）：每人一份，跟着榜一起读。
-- 所有回调都只认一次：超时、迟到、重复的回调丢掉。SDK 调用都包在 pcall 里，出错打 [RankKit] 日志。
-- simulate=true 时一律用内存里的假云端（回调推迟到下一次 Update），只给截图和自检用，正式包不要开。
-- 本地预览引擎自带一个模拟云端（用户 ID 1001、几个固定假玩家，查不了昵称），不开 simulate 时用的就是它。
local RankKit={};RankKit.__index=RankKit

-- 给玩家看的提示，一句短话；游戏可用 opts.messages 按键覆盖。
RankKit.Messages={
 no_user="登录 TapTap 后才能看排行",
 error="排行榜暂时连不上，点一下重试",
 empty="还没有人上榜",
}

-- 周期：all 为总榜（key 不带后缀），day / week / month 每期一个 key。
RankKit.Periods={"day","week","month"}

local SIM_ID="desktop-test"
local SIM_PLAYERS=20
local DAY=86400

local function log(text) print("[RankKit] "..text) end

-- 用户 ID 统一成整数字符串再比较：引擎回来的 ID 可能是整数、浮点或字符串，浮点直接 tostring 会变成 1.2e+15，对不上号。
local function idKey(v)
 if v==nil then return "" end
 if type(v)=="string" then
  if v:match("^%-?%d+$") then return v end
  local n=tonumber(v);if n and v:match("^%-?[%d%.eE%+]+$") then return idKey(n) end
  return v
 end
 if type(v)=="number" then
  local i=math.tointeger(v);if i then return tostring(i) end
  if v~=v or v==math.huge or v==-math.huge then return tostring(v) end
  return string.format("%.0f",v)
 end
 return tostring(v)
end
RankKit.IdKey=idKey

-- 当前 TapTap 账号 ID（整数字符串）；未登录、本地预览返回 nil。
function RankKit.UserId()
 local tries={
  function() return GetUserId() end,
  function() return clientCloud.userId end,
  function() return lobby:GetMyUserId() end,
 }
 for _,try in ipairs(tries) do
  local ok,v=pcall(try)
  if ok and v~=nil then
   v=idKey(v)
   if v~="" and v~="0" then return v end
  end
 end
 return nil
end

-- 某一期的云变量名：总榜就是 key；日 <key>_d20261117、周 <key>_w<周一日期>、月 <key>_m202611。tz 为时区（小时，默认北京时间 8）。
function RankKit.PeriodKey(key,period,now,tz)
 if not period or period=="all" then return key end
 local d=math.floor((now+(tz or 8)*3600)/DAY)
 if period=="day" then return key.."_d"..os.date("!%Y%m%d",d*DAY) end
 if period=="week" then return key.."_w"..os.date("!%Y%m%d",(d-(d+3)%7)*DAY) end  -- 1970-01-01 是周四，往回数到周一
 if period=="month" then return key.."_m"..os.date("!%Y%m",d*DAY) end
 error("[RankKit] 不认识的周期 "..tostring(period))
end

-- 附加资料比较用：键排序后的字符串，内容没变就不重写。
local function sig(v)
 local t=type(v)
 if t=="table" then
  local keys={};for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
  local out={};for _,k in ipairs(keys) do out[#out+1]=tostring(k).."="..sig(v[k]) end
  return "{"..table.concat(out,",").."}"
 end
 return t:sub(1,1)..tostring(v)
end

local function callable(f)
 if type(f)=="function" then return true end
 if type(f)~="table" and type(f)~="userdata" then return false end
 local ok,mt=pcall(getmetatable,f)
 return ok and type(mt)=="table" and mt.__call~=nil
end

-- 模拟用的假云端：我的分数记在内存里，另有 20 个模拟玩家，分数围绕我的分数铺开（结果固定，方便截图）。
local function fakeCloud(kit)
 local store,values={},{}
 local c={userId=SIM_ID}
 local function later(fn) kit.queue[#kit.queue+1]=fn end
 local function board(key,extra)
  local mine=store[key]
  local base=math.max(mine or 0,20)
  local list={}
  for i=1,SIM_PLAYERS do
   local item={userId=string.format("sim-%02d",i),iscore={[key]=math.max(1,math.floor(base*(2.3-.1*i)))},score={}}
   for _,k in ipairs(extra or {}) do if kit.simProfile then item.score[k]=kit.simProfile(i) end end
   list[#list+1]=item
  end
  if mine then
   local item={userId=SIM_ID,iscore={[key]=mine},score={}}
   for _,k in ipairs(extra or {}) do item.score[k]=values[k] end
   list[#list+1]=item
  end
  table.sort(list,function(a,b) return a.iscore[key]>b.iscore[key] end)
  return list
 end
 function c:SetInt(key,value,events) later(function() store[key]=value;if events and events.ok then events.ok() end end) end
 function c:Set(key,value,events) later(function() values[key]=value;if events and events.ok then events.ok() end end) end
 function c:GetRankList(key,start,count,events,...)
  local extra={...}
  later(function()
   local all,out=board(key,extra),{}
   for i=start+1,math.min(#all,start+count) do out[#out+1]=all[i] end
   events.ok(out)
  end)
 end
 function c:GetUserRank(userId,key,events)
  later(function()
   if not store[key] then return events.ok(nil,nil) end
   for i,item in ipairs(board(key)) do if item.userId==tostring(userId) then return events.ok(i,item.iscore[key]) end end
   events.ok(nil,nil)
  end)
 end
 local function nickname(opts)
  later(function()
   local out={}
   for _,id in ipairs(opts.userIds) do
    local n=tostring(id):match("^sim%-(%d+)$")
    out[#out+1]={userId=id,nickname=n and ("模拟玩家 "..n) or "我（本地）"}
   end
   opts.onSuccess(out)
  end)
 end
 return c,nickname
end

-- opts：
--  boards={[榜 id]={key=云变量名, best=true, periods={"day","week","month"}}}：key 上线后不能改名；best=false 时每次直接覆盖（默认只升不降）；
--   periods 开日 / 周 / 月榜，每期的 key 见 RankKit.PeriodKey，到点自动换新一期（总榜照常）。
--  count（每次读前几名，默认 50）、ttl（榜单缓存秒数，默认 60）、gap（同一个榜两次写入、出错后重读的最短间隔，默认 10）、
--  timeout（请求超时秒数，默认 10）、nameTimeout（查昵称超时，默认 15）、tz（换期用的时区，默认 8 北京时间）、
--  messages（覆盖提示）、onChange（某个榜的显示内容变了，参数是榜 id 和周期）。
--  profile={key=云变量名, get=function() return 表 end}：每人一份附加资料（头像、装备之类），内容变了就写，读榜时跟着带回 row.profile。key 上线后不能改名。
--  json（解码附加资料用，默认全局 cjson）。
--  simulate=true：不连云服务，用内存里的假云端（截图、自检用；别按 Platform.IsDesktopPlatform() 开，TapTap PC 版也是桌面平台）。
--   simProfile(i)：模拟玩家 i 的附加资料。
--  测试注入：cloud（同 clientCloud 的接口）、nickname（同 GetUserNickname）、userId（函数）、now（函数，返回 os.time 秒数）。
function RankKit.new(opts)
 opts=opts or {}
 local self=setmetatable({},RankKit)
 self.count=opts.count or 50
 self.ttl=opts.ttl or 60
 self.gap=opts.gap or 10
 self.timeout=opts.timeout or 10
 self.nameTimeout=opts.nameTimeout or 15
 self.tz=opts.tz or 8
 self.messages=setmetatable(opts.messages or {},{__index=RankKit.Messages})
 self.onChange=opts.onChange
 self.t=0
 self.queue={}
 self.inflight={}
 self.cloud=opts.cloud
 self.nickname=opts.nickname
 self.userId=opts.userId
 self.now=opts.now or os.time
 self.json=opts.json
 self.simulate=opts.simulate==true
 self.simProfile=opts.simProfile
 if opts.profile then
  assert(type(opts.profile.key)=="string" and opts.profile.key~="" and type(opts.profile.get)=="function","[RankKit] profile 要有 key 和 get")
  self.profile={key=opts.profile.key,get=opts.profile.get,next=0,check=0}
 end
 self.myNameNext=0
 self.boards={}
 for id,b in pairs(opts.boards or {}) do
  assert(type(b.key)=="string" and b.key~="","[RankKit] 榜 "..tostring(id).." 没有 key")
  local board={id=id,key=b.key,best=b.best~=false,subs={},list={}}
  local periods={"all"};for _,p in ipairs(b.periods or {}) do periods[#periods+1]=p end
  for _,p in ipairs(periods) do
   local sub={id=id,period=p,base=b.key,best=board.best,status="idle",rows={},next=0,gen=0}
   sub.key=RankKit.PeriodKey(b.key,p,self.now(),self.tz)
   board.subs[p]=sub;board.list[#board.list+1]=sub
  end
  self.boards[id]=board
 end
 return self
end

-- 云服务：注入的 > 模拟（simulate）> 全局 clientCloud。
function RankKit:cloud_()
 if self.cloud then return self.cloud end
 if self.simulate then
  local nick
  self.cloud,nick=fakeCloud(self)
  self.nickname=self.nickname or nick
  self.userId=self.userId or function() return SIM_ID end
  log("simulate：用内存里的假云端，不连云服务")
  return self.cloud
 end
 local ok,c=pcall(function() return clientCloud end)
 return ok and c or nil
end
function RankKit:uid_()
 if self.userId then
  local ok,v=pcall(self.userId)
  if not ok or v==nil then return nil end
  v=idKey(v);return v~="" and v or nil
 end
 return RankKit.UserId()
end
-- 查昵称的接口：注入的 > 全局 GetUserNickname（函数或可调用对象）> lobby:GetUserNickname。返回 fn, 接口名。
function RankKit:nickname_()
 if self.nickname then return self.nickname,"注入" end
 local ok,fn=pcall(function() return GetUserNickname end)
 if ok and callable(fn) then return fn,"GetUserNickname" end
 local ok2,lb=pcall(function() return lobby end)
 if ok2 and lb~=nil then
  local ok3,m=pcall(function() return lb.GetUserNickname end)
  if ok3 and callable(m) then return function(o) return m(lb,o) end,"lobby:GetUserNickname" end
 end
 return nil
end
function RankKit:json_()
 if self.json then return self.json end
 local ok,j=pcall(function() return cjson end)
 return ok and j or nil
end

function RankKit:changed_(id,period)
 if not self.onChange then return end
 local ok,err=pcall(self.onChange,id,period)
 if not ok then log("onChange 出错："..tostring(err)) end
end

-- 发一个请求：fn(events) 里调 SDK；done(ok, ...) 只回调一次，超时按失败（code="timeout"）。
function RankKit:call_(name,fn,done,timeout)
 local req={deadline=self.t+(timeout or self.timeout)}
 local finished=false
 local function finish(ok,...)
  if finished then return end
  finished=true;self.inflight[req]=nil
  local fine,err=pcall(done,ok,...)
  if not fine then log(name.." 回调出错："..tostring(err)) end
 end
 req.finish=finish
 self.inflight[req]=true
 local events={
  ok=function(...) finish(true,...) end,
  error=function(code,reason) log(name.." 失败 code="..tostring(code).." "..tostring(reason or ""));finish(false,code) end,
  timeout=function() log(name.." 超时");finish(false,"timeout") end,
 }
 local ok,err=pcall(fn,events)
 if not ok then log(name.." 调用出错："..tostring(err));finish(false,"exception") end
end

-- 用户 ID 按 SDK 的习惯传数字（模拟的 ID 不是数字就原样传）。
local function rawId(uid) return math.tointeger(tonumber(uid)) or uid end

-- 一个榜某一期；period 为 nil 是总榜。
function RankKit:sub_(id,period)
 local b=self.boards[id];return b and b.subs[period or "all"] or nil
end

---------------------------------------------------------------- 上报
-- 报一个分数（总榜和各期一起报）。小于 1、没涨（best）或没变的不写；第一次先读云端已有的分数，只有更高才写。
-- 同一个榜两次写入至少隔 gap 秒，期间只记最新值；写失败过 gap 秒再试。没登录时先记着，登录后补写。
function RankKit:Submit(id,value)
 local board=self.boards[id];value=math.floor(tonumber(value) or 0)
 if not board or value<1 then return end
 for _,b in ipairs(board.list) do
  local skip=(b.best and b.sent and value<=b.sent) or (not b.best and value==b.sent) or (b.best and b.pending and value<=b.pending)
  if not skip then b.pending=value;self:flush_(b) end
 end
end

function RankKit:flush_(b)
 if not b.pending or b.busy or self.t<b.next then return end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then return end
 b.busy=true
 local gen,key=b.gen,b.key
 if b.best and b.sent==nil then
  -- 先读云端的分数：重装、换手机后本地从 0 开始，别把历史最高覆盖掉
  self:call_("读取已有分数 "..key,function(ev) cloud:GetUserRank(rawId(uid),key,ev) end,function(ok,_,score)
   if gen~=b.gen then return end
   b.busy=false
   if ok then b.sent=math.floor(tonumber(score) or 0);self:flush_(b) else b.next=self.t+self.gap end
  end)
  return
 end
 if b.best and b.pending<=b.sent then b.pending=nil;b.busy=false;return end
 local v=b.pending
 b.next=self.t+self.gap
 self:call_("写入 "..key,function(ev) cloud:SetInt(key,v,ev) end,function(ok)
  if gen~=b.gen then return end
  b.busy=false
  if not ok then return end
  b.sent=b.best and math.max(b.sent or 0,v) or v
  if b.pending==v or (b.best and b.pending and b.pending<=b.sent) then b.pending=nil end
  -- 缓存的榜单里还是旧分数：下次 Fetch 重读
  if b.status=="ok" then b.at=nil end
 end)
end

-- 换期：这一期的 key 变了就清空，之后的 Submit 写进新一期；还没回来的旧请求按 gen 丢掉。
function RankKit:roll_()
 local now=self.now()
 for _,board in pairs(self.boards) do
  for _,b in ipairs(board.list) do
   local key=RankKit.PeriodKey(b.base,b.period,now,self.tz)
   if key~=b.key then
    b.key=key;b.gen=b.gen+1
    b.sent=nil;b.pending=nil;b.busy=false;b.next=0
    b.rows={};b.me=nil;b.at=nil;b.loading=false;b.status="idle";b.message=nil
    self:changed_(b.id,b.period)
   end
  end
 end
end

-- 附加资料：每秒看一次，内容变了就写（至少隔 gap 秒）；没登录先等着。
function RankKit:profileFlush_()
 local pf=self.profile
 if not pf or pf.busy or self.t<pf.check then return end
 pf.check=self.t+1
 if self.t<pf.next then return end
 local ok,v=pcall(pf.get)
 if not ok then log("profile.get 出错："..tostring(v));return end
 if v==nil then return end
 local s=sig(v)
 if s==pf.sent then return end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then return end
 pf.busy=true;pf.next=self.t+self.gap
 self:call_("写入资料 "..pf.key,function(ev) cloud:Set(pf.key,v,ev) end,function(fine)
  pf.busy=false
  if fine then pf.sent=s end
 end)
end

---------------------------------------------------------------- 读榜
-- 回包里的一条：昵称字段认 nickname / nickName / name，ID 字段认 userId / user_id / id。
local function pickName(info)
 if type(info)~="table" then return nil end
 for _,k in ipairs({"nickname","nickName","name"}) do local v=info[k];if type(v)=="string" and v~="" then return v end end
 return nil
end
local function pickId(info)
 if type(info)~="table" then return nil end
 local v=info.userId;if v==nil then v=info.user_id end;if v==nil then v=info.id end
 return v
end
-- 回包整理成 {[ID]=昵称} 和按顺序的昵称；数组和 {[ID]=昵称} 映射两种形状都认。返回 map, seq, 条数, 第一条（日志用）。
local function parseNames(list)
 local map,seq,n,first={},{},0,nil
 if type(list)~="table" then return map,seq,0,list end
 if #list>0 then
  for i,info in ipairs(list) do
   n=n+1;first=first or info
   local name=pickName(info);local id=pickId(info)
   seq[i]=name or false
   if name and id~=nil then map[idKey(id)]=name end
  end
 else
  for k,v in pairs(list) do
   n=n+1;first=first or {key=k,value=v}
   local name=type(v)=="string" and v or pickName(v)
   local id=type(v)=="table" and pickId(v) or nil;if id==nil then id=k end
   if name and name~="" then map[idKey(id)]=name end
  end
 end
 return map,seq,n,first
end
-- 日志里描述一条回包：字段类型和值，查「对不上号」用。
local function describe(info)
 if type(info)~="table" then return type(info)..":"..tostring(info) end
 local keys={};for k,v in pairs(info) do keys[#keys+1]=tostring(k).."="..type(v)..":"..tostring(v) end
 table.sort(keys)
 return "{"..table.concat(keys,", ").."}"
end

-- 给 rows 配昵称：每批 50 个，整批失败拆成每批 10 个再试一次；查不到的显示「玩家」+ ID 后 4 位。
-- 每次打一行日志：用的哪个接口、问了几个、回了几个、对上几个；有没对上的附第一条回包，真机上靠它查原因。
function RankKit:names_(rows,done)
 for _,r in ipairs(rows) do r.name="玩家"..r.userId:sub(-4);r.named=false end
 if #rows==0 then return done() end
 local fn,via=self:nickname_()
 if not fn then
  if not self.noNickLogged then self.noNickLogged=true;log("昵称：找不到 GetUserNickname / lobby:GetUserNickname，显示「玩家」+ ID 后 4 位") end
  return done()
 end
 local st={got=0,hit=0,fail={},order=false,first=nil}
 local left=1
 local function finishOne()
  left=left-1
  if left>0 then return end
  local line=string.format("昵称：%s 问 %d 个，回 %d 个，对上 %d 个",via,#rows,st.got,st.hit)
  if st.order then line=line.."（ID 对不上，按顺序对位）" end
  if #st.fail>0 then line=line.."，失败 "..table.concat(st.fail,"/") end
  if st.hit<#rows and st.first~=nil then line=line.."；第一条回包 "..describe(st.first).."，第一行 ID "..rows[1].userId end
  log(line)
  done()
 end
 local function apply(first,last,list)
  local map,seq,n,firstInfo=parseNames(list)
  st.got=st.got+n;if st.first==nil then st.first=firstInfo end
  local hit=0
  for k=first,last do local name=map[rows[k].userId];if name then rows[k].name=name;rows[k].named=true;hit=hit+1 end end
  -- 一个都没对上、条数正好相等：按顺序对位
  if hit==0 and #seq==last-first+1 then
   for k=first,last do local name=seq[k-first+1];if name then rows[k].name=name;rows[k].named=true;hit=hit+1 end end
   if hit>0 then st.order=true end
  end
  st.hit=st.hit+hit
 end
 local function batch(first,last,retry)
  left=left+1
  local ids={};for k=first,last do ids[#ids+1]=rawId(rows[k].userId) end
  self:call_("查询昵称",function(ev) fn({userIds=ids,onSuccess=ev.ok,onError=ev.error}) end,function(ok,list)
   if ok then apply(first,last,list)
   elseif retry and last-first+1>10 then
    for s=first,last,10 do batch(s,math.min(last,s+9),false) end
   else st.fail[#st.fail+1]=tostring(list) end
   finishOne()
  end,self.nameTimeout)
 end
 for first=1,#rows,50 do batch(first,math.min(#rows,first+49),true) end
 finishOne()
end

-- 自己的昵称（底部「我」那行用）：榜上有自己就用榜上的，否则单独查一次；查不到隔一会儿再试。
function RankKit:myName_(uid,rows)
 for _,r in ipairs(rows) do if r.me and r.named then self.myName=r.name;return end end
 if self.myName or self.myNameBusy or self.t<self.myNameNext then return end
 self.myNameBusy=true
 local one={{userId=uid}}
 self:names_(one,function()
  self.myNameBusy=false
  if one[1].named then self.myName=one[1].name;self:changed_() else self.myNameNext=self.t+self.gap*6 end
 end)
end

-- 附加资料：表直接用，字符串按 JSON 解一次。
function RankKit:profileOf_(item)
 local pf=self.profile;if not pf then return nil end
 local score=type(item.score)=="table" and item.score or nil
 local v=score and score[pf.key]
 if type(v)=="string" then
  local j=self:json_()
  if j then local ok,t=pcall(j.decode,v);v=ok and type(t)=="table" and t or nil else v=nil end
 end
 return type(v)=="table" and v or nil
end

-- 读一个榜某一期：前 count 名 → 昵称 → 我的名次。缓存没过期、正在读时不重读；出错后 gap 秒内不自动重读。force 立刻重读。
function RankKit:Fetch(id,force,period)
 local b=self:sub_(id,period)
 if not b or b.loading then return end
 if not force and b.at then
  local age=self.t-b.at
  if b.status=="ok" and age<self.ttl then return end
  if b.status=="error" and age<self.gap then return end
 end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then
  b.status="error";b.message=self.messages.no_user;b.at=self.t;self:changed_(b.id,b.period)
  return
 end
 b.loading=true
 if b.status~="ok" then b.status="loading";b.message=nil end
 self:changed_(b.id,b.period)
 local gen,key=b.gen,b.key
 local pk=self.profile and self.profile.key
 local function fail()
  if gen~=b.gen then return end
  b.loading=false;b.status="error";b.message=self.messages.error;b.at=self.t;self:changed_(b.id,b.period)
 end
 self:call_("读取排行 "..key,function(ev)
  if pk then cloud:GetRankList(key,0,self.count,ev,pk) else cloud:GetRankList(key,0,self.count,ev) end
 end,function(ok,list)
  if not ok then return fail() end
  if gen~=b.gen then return end
  local rows={}
  for _,item in ipairs(type(list)=="table" and list or {}) do
   if type(item)=="table" then
    local raw=item.userId;if raw==nil then raw=item.player end
    local iscore=type(item.iscore)=="table" and item.iscore or {}
    local sid=idKey(raw)
    rows[#rows+1]={rank=#rows+1,userId=sid,score=math.floor(tonumber(iscore[key]) or 0),me=sid==uid,profile=self:profileOf_(item)}
   end
  end
  self:names_(rows,function()
   if gen~=b.gen then return end
   self:myName_(uid,rows)
   local mine;for _,r in ipairs(rows) do if r.me then mine=r end end
   self:call_("查询名次 "..key,function(ev) cloud:GetUserRank(rawId(uid),key,ev) end,function(ok2,rank,score)
    if gen~=b.gen then return end
    rank=ok2 and tonumber(rank) or nil
    -- 名次从 0 还是 1 数：自己在榜上时对一次，榜外的名次按同样的差补
    if mine and rank then self.rankBase=mine.rank-rank end
    if mine then b.me={rank=mine.rank,score=mine.score}
    elseif rank then b.me={rank=rank+(self.rankBase or 0),score=math.floor(tonumber(score) or 0)}
    else b.me=nil end
    -- 榜上的分数比已知的高（别的设备写的）：以后按它比较，不往下写
    if b.best and b.sent~=nil and b.me and b.me.score>b.sent then b.sent=b.me.score end
    b.rows=rows;b.loading=false;b.status="ok";b.at=self.t
    b.message=#rows==0 and self.messages.empty or nil
    self:changed_(b.id,b.period)
   end)
  end)
 end)
end

-- 一个榜某一期现在要显示的内容：status 为 idle / loading / ok / error；rows 为 {rank,userId,name,named,score,me,profile}；
-- me 为 {rank,score}（不在榜上为 nil）；message 为出错、没登录或空榜时的提示；loading 为正在后台刷新（status 可能仍是 ok）；
-- myName 为自己的 TapTap 昵称（还没查到为 nil）。
function RankKit:View(id,period)
 local b=self:sub_(id,period)
 if not b then return {status="idle",rows={},loading=false,myName=self.myName} end
 return {status=b.status,rows=b.rows,me=b.me,message=b.message,loading=b.loading==true,myName=self.myName}
end

-- 每帧调：推进模拟回调、判断超时、换期、补写待写的分数和附加资料。
function RankKit:Update(dt)
 self.t=self.t+(dt or 0)
 if #self.queue>0 then
  local q=self.queue;self.queue={}
  for _,fn in ipairs(q) do local ok,err=pcall(fn);if not ok then log("模拟回调出错："..tostring(err)) end end
 end
 local late={}
 for req in pairs(self.inflight) do if self.t>=req.deadline then late[#late+1]=req end end
 for _,req in ipairs(late) do log("请求超时");req.finish(false,"timeout") end
 if self.t>=(self.rollAt or 0) then self.rollAt=self.t+1;self:roll_() end
 for _,board in pairs(self.boards) do for _,b in ipairs(board.list) do self:flush_(b) end end
 self:profileFlush_()
end

return RankKit
