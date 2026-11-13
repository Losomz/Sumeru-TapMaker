-- 广告奖励统一入口：业务按钮只管调用 Reward(key,grant) 发奖，不判断免广、也不自己计次。
-- 入口先查当天总上限和这个广告点的上限；免广时不播广告直接发奖，否则播激励视频，完整看完才发奖并推进免广进度。
-- 规则在 AdFree，播放在 AdKit；游戏只注入存档里的状态、提示、存档，以及播放前后的钩子（暂停、埋点广告位等）。
---@class SumeruAdReward
local AdReward={};AdReward.__index=AdReward

-- 默认提示文案；游戏在 new 时用 texts 覆盖其中几条即可。带 %d 的参数顺序见每行注释。
AdReward.TEXTS={
 cap="今天的广告次数用完了，明天再来",
 limit="今天的次数用完了，明天再来",
 unavailable="广告暂不可用，请稍后重试",
 incomplete="需完整观看广告才能获得奖励",
 failed="广告播放失败，请稍后重试",
 progress="免广进度 %d/%d",              -- 当天已看、当天目标
 qualified="今日免广已解锁",
 passStarted="连续 %d 天达标，免广 %d 天",  -- 连续天数、免广天数
 freeToday="今天已经免广了",
 freePass="免广中，还剩 %d 天",           -- 剩余天数
 claimed="今日 %d/%d",                   -- 当天已领、当天总上限
}

---@param config {ad:SumeruAdKit,rules:SumeruAdFree,state:fun():table,notice:fun(text:string)?,save:fun()?,onStart:fun(placement:string?)?,onEnd:fun()?,texts:table<string,string>?}
function AdReward.new(config)
 local self=setmetatable({},AdReward)
 self.ad=assert(config.ad,"AdReward 需要 ad（AdKit 实例）")
 self.rules=assert(config.rules,"AdReward 需要 rules（AdFree 实例）")
 self.state=assert(config.state,"AdReward 需要 state（返回存档里免广状态表的函数）")
 self.notice=config.notice;self.save=config.save;self.onStart=config.onStart;self.onEnd=config.onEnd
 self.texts={}
 for k,v in pairs(AdReward.TEXTS) do self.texts[k]=v end
 for k,v in pairs(config.texts or {}) do self.texts[k]=v end
 return self
end

function AdReward:IsBusy() return self.ad:IsBusy() end
function AdReward:Status() return self.rules:Status(self.state()) end
function AdReward:IsFree() return self:Status().free end
-- 某个广告点今天还能领几次（已算上当天总上限）。
function AdReward:Left(key) return self.rules:Left(self.state(),key) end

local function say(self,text) if text and self.notice then self.notice(text) end end
local function persist(self) if self.save then self.save() end end
local function join(a,b) if a and b then return a.." · "..b end return a or b end

-- 看完一次广告后的进度提示：刚开启长期免广、刚看满、进度 +1 三选一；没推进进度时为 nil。
function AdReward:ProgressText(out)
 local r,t=self.rules,self.texts
 if out.passStarted then return t.passStarted:format(r.streakDays,r.passDays) end
 if out.qualified then return t.qualified end
 if out.counted then return t.progress:format(out.todayViews,r.dailyTarget) end
 return nil
end

-- 播一次激励视频：完整看完才计次、交给 onDone(outcome) 并存档；没看完或不可用只提示。
-- AdKit 保证回调恰好一次，所以 onStart 之后 onEnd 一定会被调用。
local function play(self,placement,onDone)
 if not self.ad:CanRequest() then say(self,self.texts.unavailable);return false end
 if self.onStart then self.onStart(placement) end
 return self.ad:ShowRewardVideo(function(result)
  if self.onEnd then self.onEnd() end
  if result.success==true then
   onDone(self.rules:RecordView(self.state()))
   persist(self)
  elseif result.msg=="embed manual close" then say(self,self.texts.incomplete)
  else say(self,self.texts.failed) end
 end)
end

-- 广告奖励唯一入口。key 是广告点：按它限次，也作为数据后台的广告位名（交给 onStart）。
-- grant() 发奖并返回提示；返回 nil 表示奖励已失效，不发也不计这个点的次数（看完的那次广告照样计入当天总次数）。
-- 返回 true 表示已经免广直领，或广告已经开始播放。
---@param key string
---@param grant fun():string?
---@return boolean
function AdReward:Reward(key,grant)
 if self.ad:IsBusy() then return false end
 local state=self.state()
 local ok,why=self.rules:Check(state,key)
 if not ok then say(self,self.texts[why]);return false end
 if self.rules:IsFree(state) then
  local text=grant()
  if not text then return false end
  self.rules:RecordFree(state);self.rules:AddUse(state,key)
  local s=self.rules:Status(state)
  say(self,join(text,self.texts.claimed:format(s.todayTotal,s.dailyCap)))
  persist(self)
  return true
 end
 return play(self,key,function(out)
  local text=grant()
  if text then self.rules:AddUse(self.state(),key) end
  say(self,join(text,self:ProgressText(out)))
 end)
end

-- 只看广告推进免广进度、没有奖励（如公告栏的「看广告 · 免广进度 +1」）；已免广时不播。同样占当天总次数。
---@param placement string 数据后台的广告位名
---@return boolean
function AdReward:Watch(placement)
 if self.ad:IsBusy() then return false end
 local state=self.state();local s=self.rules:Status(state)
 if s.pass then say(self,self.texts.freePass:format(s.passDaysLeft));return false end
 if s.qualifiedToday then say(self,self.texts.freeToday);return false end
 local ok,why=self.rules:Check(state,nil)
 if not ok then say(self,self.texts[why]);return false end
 return play(self,placement,function(out) say(self,self:ProgressText(out)) end)
end

return AdReward
