-- 排行榜：分数写进 clientCloud 的整数云变量（iscores），按 key 读榜、配上 TapTap 昵称、查自己的名次。
-- 每个榜一个 key；默认只记历史最高（存档在本机，重装后本地从 0 开始，不能把云端的成绩覆盖掉）。
-- 所有回调都只认一次：超时、迟到、重复的回调丢掉。SDK 调用都包在 pcall 里，出错打 [RankKit] 日志。
-- simulate=true 时一律用内存里的假云端（回调推迟到下一次 Update），只给截图和自检用，正式包不要开。
-- 本地预览引擎自带一个模拟云端（用户 ID 1001、几个固定假玩家，查不了昵称），不开 simulate 时用的就是它。
local RedeemKit=require("sumeru.toolkit.redeemkit.RedeemKit")

local RankKit={};RankKit.__index=RankKit

-- 给玩家看的提示，一句短话；游戏可用 opts.messages 按键覆盖。
RankKit.Messages={
 no_user="登录 TapTap 后才能看排行",
 error="排行榜暂时连不上，点一下重试",
 empty="还没有人上榜",
}

-- 当前 TapTap 账号 ID（字符串）；未登录、本地预览返回 nil。和兑换码用的是同一个。
RankKit.UserId=RedeemKit.UserId

local SIM_ID="desktop-test"
local SIM_PLAYERS=20

local function log(text) print("[RankKit] "..text) end

-- 模拟用的假云端：我的分数记在内存里，另有 20 个模拟玩家，分数围绕我的分数铺开（结果固定，方便截图）。
local function fakeCloud(kit)
 local store={}
 local c={userId=SIM_ID}
 local function later(fn) kit.queue[#kit.queue+1]=fn end
 local function board(key)
  local mine=store[key]
  local base=math.max(mine or 0,20)
  local list={}
  for i=1,SIM_PLAYERS do list[#list+1]={userId=string.format("sim-%02d",i),iscore={[key]=math.max(1,math.floor(base*(2.3-.1*i)))}} end
  if mine then list[#list+1]={userId=SIM_ID,iscore={[key]=mine}} end
  table.sort(list,function(a,b) return a.iscore[key]>b.iscore[key] end)
  return list
 end
 function c:SetInt(key,value,events) later(function() store[key]=value;if events and events.ok then events.ok() end end) end
 function c:GetRankList(key,start,count,events)
  later(function()
   local all,out=board(key),{}
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
--  boards={[榜 id]={key=云变量名, best=true}}：key 上线后不能改名；best=false 时每次直接覆盖（默认只升不降）。
--  count（每次读前几名，默认 50）、ttl（榜单缓存秒数，默认 60）、gap（同一个榜两次写入、出错后重读的最短间隔，默认 10）、
--  timeout（请求超时秒数，默认 10）、messages（覆盖提示）、onChange（某个榜的显示内容变了，参数是榜 id）。
--  simulate=true：不连云服务，用内存里的假云端（截图、自检用；别按 Platform.IsDesktopPlatform() 开，TapTap PC 版也是桌面平台）。
--  测试注入：cloud（同 clientCloud 的接口）、nickname（同 GetUserNickname）、userId（函数）。
function RankKit.new(opts)
 opts=opts or {}
 local self=setmetatable({},RankKit)
 self.count=opts.count or 50
 self.ttl=opts.ttl or 60
 self.gap=opts.gap or 10
 self.timeout=opts.timeout or 10
 self.messages=setmetatable(opts.messages or {},{__index=RankKit.Messages})
 self.onChange=opts.onChange
 self.t=0
 self.queue={}
 self.inflight={}
 self.cloud=opts.cloud
 self.nickname=opts.nickname
 self.userId=opts.userId
 self.simulate=opts.simulate==true
 self.boards={}
 for id,b in pairs(opts.boards or {}) do
  assert(type(b.key)=="string" and b.key~="","[RankKit] 榜 "..tostring(id).." 没有 key")
  self.boards[id]={id=id,key=b.key,best=b.best~=false,status="idle",rows={},next=0}
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
 if self.userId then local ok,v=pcall(self.userId);return ok and v~=nil and tostring(v) or nil end
 return RankKit.UserId()
end
function RankKit:nickname_()
 if self.nickname then return self.nickname end
 local ok,fn=pcall(function() return GetUserNickname end)
 return ok and type(fn)=="function" and fn or nil
end

function RankKit:changed_(id)
 if not self.onChange then return end
 local ok,err=pcall(self.onChange,id)
 if not ok then log("onChange 出错："..tostring(err)) end
end

-- 发一个请求：fn(events) 里调 SDK；done(ok, ...) 只回调一次，超时按失败（code="timeout"）。
function RankKit:call_(name,fn,done)
 local req={deadline=self.t+self.timeout}
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
local function rawId(uid) return tonumber(uid) or uid end

---------------------------------------------------------------- 上报
-- 报一个分数。小于 1、没涨（best）或没变的不写；第一次先读云端已有的分数，只有更高才写。
-- 同一个榜两次写入至少隔 gap 秒，期间只记最新值；写失败过 gap 秒再试。没登录时先记着，登录后补写。
function RankKit:Submit(id,value)
 local b=self.boards[id];value=math.floor(tonumber(value) or 0)
 if not b or value<1 then return end
 if b.best and b.sent and value<=b.sent then return end
 if not b.best and value==b.sent then return end
 if b.best and b.pending and value<=b.pending then return end
 b.pending=value
 self:flush_(b)
end

function RankKit:flush_(b)
 if not b.pending or b.busy or self.t<b.next then return end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then return end
 b.busy=true
 if b.best and b.sent==nil then
  -- 先读云端的分数：重装、换手机后本地从 0 开始，别把历史最高覆盖掉
  self:call_("读取已有分数",function(ev) cloud:GetUserRank(rawId(uid),b.key,ev) end,function(ok,_,score)
   b.busy=false
   if ok then b.sent=math.floor(tonumber(score) or 0);self:flush_(b) else b.next=self.t+self.gap end
  end)
  return
 end
 if b.best and b.pending<=b.sent then b.pending=nil;b.busy=false;return end
 local v=b.pending
 b.next=self.t+self.gap
 self:call_("写入 "..b.key,function(ev) cloud:SetInt(b.key,v,ev) end,function(ok)
  b.busy=false
  if not ok then return end
  b.sent=b.best and math.max(b.sent or 0,v) or v
  if b.pending==v or (b.best and b.pending and b.pending<=b.sent) then b.pending=nil end
  -- 缓存的榜单里还是旧分数：下次 Fetch 重读
  if b.status=="ok" then b.at=nil end
 end)
end

---------------------------------------------------------------- 读榜
-- 给 rows 配昵称：每批 50 个；查不到的显示「玩家」+ ID 后 4 位。
function RankKit:names_(rows,done)
 for _,r in ipairs(rows) do r.name="玩家"..r.userId:sub(-4) end
 local fn=self:nickname_()
 if not fn or #rows==0 then return done() end
 local left=0
 for first=1,#rows,50 do
  local last=math.min(#rows,first+49)
  local ids={};for k=first,last do ids[#ids+1]=rows[k].raw end
  left=left+1
  self:call_("查询昵称",function(ev) fn({userIds=ids,onSuccess=ev.ok,onError=ev.error}) end,function(ok,list)
   if ok and type(list)=="table" then
    local map={}
    for _,info in ipairs(list) do if type(info)=="table" and info.userId~=nil then map[tostring(info.userId)]=info.nickname end end
    for k=first,last do local n=map[rows[k].userId];if type(n)=="string" and n~="" then rows[k].name=n end end
   end
   left=left-1
   if left==0 then done() end
  end)
 end
end

-- 读一个榜：前 count 名 → 昵称 → 我的名次。缓存没过期、正在读时不重读；出错后 gap 秒内不自动重读。force 立刻重读。
function RankKit:Fetch(id,force)
 local b=self.boards[id]
 if not b or b.loading then return end
 if not force and b.at then
  local age=self.t-b.at
  if b.status=="ok" and age<self.ttl then return end
  if b.status=="error" and age<self.gap then return end
 end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then
  b.status="error";b.message=self.messages.no_user;b.at=self.t;self:changed_(id)
  return
 end
 b.loading=true
 if b.status~="ok" then b.status="loading";b.message=nil end
 self:changed_(id)
 local function fail()
  b.loading=false;b.status="error";b.message=self.messages.error;b.at=self.t;self:changed_(id)
 end
 self:call_("读取排行 "..b.key,function(ev) cloud:GetRankList(b.key,0,self.count,ev) end,function(ok,list)
  if not ok then return fail() end
  local rows={}
  for _,item in ipairs(type(list)=="table" and list or {}) do
   if type(item)=="table" then
    local raw=item.userId;if raw==nil then raw=item.player end
    local iscore=type(item.iscore)=="table" and item.iscore or {}
    local sid=raw~=nil and tostring(raw) or ""
    rows[#rows+1]={rank=#rows+1,userId=sid,raw=raw,score=math.floor(tonumber(iscore[b.key]) or 0),me=sid==uid}
   end
  end
  self:names_(rows,function()
   local mine;for _,r in ipairs(rows) do if r.me then mine=r end end
   self:call_("查询名次 "..b.key,function(ev) cloud:GetUserRank(rawId(uid),b.key,ev) end,function(ok2,rank,score)
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
    self:changed_(id)
   end)
  end)
 end)
end

-- 一个榜现在要显示的内容：status 为 idle / loading / ok / error；rows 为 {rank,userId,name,score,me}；
-- me 为 {rank,score}（不在榜上为 nil）；message 为出错、没登录或空榜时的提示；loading 为正在后台刷新（status 可能仍是 ok）。
function RankKit:View(id)
 local b=self.boards[id]
 if not b then return {status="idle",rows={},loading=false} end
 return {status=b.status,rows=b.rows,me=b.me,message=b.message,loading=b.loading==true}
end

-- 每帧调：推进模拟回调、判断超时、补写待写的分数。
function RankKit:Update(dt)
 self.t=self.t+(dt or 0)
 if #self.queue>0 then
  local q=self.queue;self.queue={}
  for _,fn in ipairs(q) do local ok,err=pcall(fn);if not ok then log("模拟回调出错："..tostring(err)) end end
 end
 local late={}
 for req in pairs(self.inflight) do if self.t>=req.deadline then late[#late+1]=req end end
 for _,req in ipairs(late) do log("请求超时");req.finish(false,"timeout") end
 for _,b in pairs(self.boards) do self:flush_(b) end
end

return RankKit
