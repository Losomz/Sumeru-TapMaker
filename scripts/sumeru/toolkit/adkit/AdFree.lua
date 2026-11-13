-- 广告次数与免广规则（纯数据，不播广告）：每天广告奖励总上限、各广告点每天上限、当天看满免广、连续达标后长期免广。
-- 状态是一张普通表，由游戏放进存档（结构用 AdFree.Schema() 声明）；每个方法都先按本地日历跨天清零。
-- 播放与发奖的统一入口见 AdReward。
---@class SumeruAdFree
---@field dailyTarget integer 当天完整看满几次，当天剩下的广告奖励直接领
---@field streakDays integer 连续几天看满，开启长期免广
---@field passDays integer 长期免广持续几天（开启当天算第 1 天）
---@field dailyCap integer 每天广告奖励总次数：看广告和免广直领合计，免不免广都一样
---@field limits table<string,integer> 各广告点每天上限；没登记的只受总上限约束
local AdFree={};AdFree.__index=AdFree

AdFree.DEFAULTS={dailyTarget=15,streakDays=3,passDays=15,dailyCap=50}

---@param config {dailyTarget:integer?,streakDays:integer?,passDays:integer?,dailyCap:integer?,limits:table<string,integer>?}?
function AdFree.new(config)
 config=config or {}
 local self=setmetatable({},AdFree)
 for k,v in pairs(AdFree.DEFAULTS) do self[k]=math.max(1,math.floor(tonumber(config[k]) or v)) end
 self.limits=config.limits or {}
 return self
end

-- 存档结构声明（SaveKit）。permanent、freeUses 是旧版免广存档的字段，读档时 Normalize 转换一次，之后恒为默认值。
function AdFree.Schema()
 local map=require("sumeru.toolkit.savekit").map
 return {todayKey="",todayViews=0,todayTotal=0,used=map(0),streak=0,lastQualifiedKey="",passUntil="",permanent=false,freeUses=0}
end

local function validKey(v) return type(v)=="string" and v:match("^%d%d%d%d%-%d%d%-%d%d$")~=nil end
local function keyAt(t) return os.date("%Y-%m-%d",t or os.time()) end
-- 日期键当天中午的时间戳，损坏的日期返回 nil。
local function noonOf(key)
 if not validKey(key) then return nil end
 local y,m,d=key:match("^(%d+)%-(%d+)%-(%d+)$")
 local ok,t=pcall(os.time,{year=tonumber(y),month=tonumber(m),day=tonumber(d),hour=12})
 return ok and t or nil
end
local function shiftKey(key,days) local t=noonOf(key);return t and keyAt(t+days*86400) or nil end
local function count(v,max) return math.max(0,math.min(max,math.floor(tonumber(v) or 0))) end

-- 跨天清零当天计数；长期免广过了最后一天就清空；不在长期免广期间又漏掉一天，连续天数归零。
function AdFree:Sync(state,now)
 local today=keyAt(now)
 if type(state.used)~="table" then state.used={} end
 if state.todayKey~=today then state.todayKey=today;state.todayViews=0;state.todayTotal=0;state.used={} end
 if not validKey(state.passUntil) or today>state.passUntil then state.passUntil="" end
 if not validKey(state.lastQualifiedKey) then state.lastQualifiedKey="" end
 if state.passUntil=="" and state.lastQualifiedKey~="" and state.lastQualifiedKey~=today and state.lastQualifiedKey~=shiftKey(today,-1) then state.streak=0 end
 state.todayViews=count(state.todayViews,self.dailyTarget)
 state.todayTotal=count(state.todayTotal,self.dailyCap)
 state.streak=count(state.streak,self.streakDays)
 return state
end

-- 读档后调用一次，返回整理好的状态：只接受合法字段；
-- 旧版永久免广改成从今天起的长期免广，旧版当天免广直领次数并进当天总次数。
function AdFree:Normalize(saved,now)
 saved=type(saved)=="table" and saved or {}
 local state={todayKey=validKey(saved.todayKey) and saved.todayKey or keyAt(now),
  todayViews=count(saved.todayViews,self.dailyTarget),todayTotal=count(saved.todayTotal,self.dailyCap),used={},
  streak=count(saved.streak,self.streakDays),lastQualifiedKey=validKey(saved.lastQualifiedKey) and saved.lastQualifiedKey or "",
  passUntil=validKey(saved.passUntil) and saved.passUntil or "",permanent=false,freeUses=0}
 if type(saved.used)=="table" then
  for k,n in pairs(saved.used) do if type(k)=="string" then state.used[k]=count(n,math.huge) end end
 end
 state.todayTotal=math.max(state.todayTotal,math.min(self.dailyCap,state.todayViews+count(saved.freeUses,self.dailyCap)))
 if saved.permanent==true and state.passUntil=="" then state.passUntil=shiftKey(keyAt(now),self.passDays-1) or "" end
 return self:Sync(state,now)
end

-- 今天到 passUntil 含首尾还有几天，夹在 0–passDays（系统时间往回调也不会超过 passDays）。
local function daysLeft(today,untilKey,passDays)
 local from,to=noonOf(today),noonOf(untilKey)
 if not from or not to then return 0 end
 return math.max(0,math.min(passDays,math.floor((to-from)/86400+0.5)+1))
end

-- UI 用的摘要：free 现在是否免广（长期免广中或今天已看满）；left 今天还能领几次广告奖励。
function AdFree:Status(state,now)
 self:Sync(state,now)
 local pass=state.passUntil~=""
 local qualified=state.todayViews>=self.dailyTarget
 return {free=pass or qualified,pass=pass,passUntil=state.passUntil,passDaysLeft=pass and daysLeft(state.todayKey,state.passUntil,self.passDays) or 0,
  qualifiedToday=qualified,todayViews=state.todayViews,dailyTarget=self.dailyTarget,
  streak=state.streak,streakDays=self.streakDays,passDays=self.passDays,
  todayTotal=state.todayTotal,dailyCap=self.dailyCap,left=self.dailyCap-state.todayTotal}
end
function AdFree:IsFree(state,now) return self:Status(state,now).free end

-- 某个广告点今天还能领几次：取该点上限和当天总上限里较小的；key 为 nil 或没登记上限时只看总上限。
function AdFree:Left(state,key,now)
 self:Sync(state,now)
 local left=self.dailyCap-state.todayTotal
 local limit=key and self.limits[key]
 if limit then left=math.min(left,limit-(state.used[key] or 0)) end
 return math.max(0,left)
end

-- 现在能不能再领一次：不能时第二个返回值是原因，"cap" 当天总次数用完，"limit" 这个广告点今天用完。
---@return boolean ok
---@return "cap"|"limit"|nil reason
function AdFree:Check(state,key,now)
 self:Sync(state,now)
 if state.todayTotal>=self.dailyCap then return false,"cap" end
 local limit=key and self.limits[key]
 if limit and (state.used[key] or 0)>=limit then return false,"limit" end
 return true
end

-- 完整看完一次广告（只由播放成功回调调用）：计入当天总次数；不在免广时推进当天进度，
-- 看满即当天免广，连续 streakDays 天看满开启 passDays 天免广。
-- 返回 {counted=推进了进度, todayViews=当天进度, qualified=这次刚看满, passStarted=这次刚开启长期免广}。
function AdFree:RecordView(state,now)
 self:Sync(state,now)
 state.todayTotal=math.min(self.dailyCap,state.todayTotal+1)
 local out={counted=false,qualified=false,passStarted=false,todayViews=state.todayViews}
 if state.passUntil~="" or state.todayViews>=self.dailyTarget then return out end
 state.todayViews=state.todayViews+1;out.counted=true;out.todayViews=state.todayViews
 if state.todayViews>=self.dailyTarget then
  out.qualified=true
  local today=state.todayKey
  state.streak=state.lastQualifiedKey==shiftKey(today,-1) and math.min(self.streakDays,state.streak+1) or 1
  state.lastQualifiedKey=today
  if state.streak>=self.streakDays then
   state.passUntil=shiftKey(today,self.passDays-1) or "";out.passStarted=state.passUntil~=""
  end
 end
 return out
end

-- 免广时直接领了一次奖励：计入当天总次数。
function AdFree:RecordFree(state,now)
 self:Sync(state,now)
 state.todayTotal=math.min(self.dailyCap,state.todayTotal+1)
end

-- 某个广告点的奖励真正发出去后计一次（key 为 nil 时不计）。
function AdFree:AddUse(state,key,now)
 self:Sync(state,now)
 if key then state.used[key]=(state.used[key] or 0)+1 end
end

return AdFree
