-- 时间线：一组共用倍速与暂停的更新成员。设了 step 时按积攒时间逐个固定步长推进，没设时每帧推进一次；不依赖引擎、UI 或业务。
-- 成员是函数 fn(dt,line)，或带 :Tick(dt,line) 方法的表；按 priority 从小到大执行，同级按加入顺序。适合按 System 拆分：每个成员只推进自己负责的那类对象。
---@alias SumeruTickTarget fun(dt:number,line:SumeruTimeline)|{Tick:fun(self:table,dt:number,line:SumeruTimeline)}
---@class SumeruTimeline
---@field name string
---@field step number? 固定步长（秒）；nil 表示每帧推进一次
---@field maxDelta number 单帧真实时间上限（秒），先截断再乘倍速
---@field maxSteps integer? 单帧最多执行的固定步数，超出时丢弃剩余积攒时间
---@field scale_ number
---@field holds_ table<string,boolean>
---@field holdCount_ integer
---@field acc_ number
---@field time_ number
---@field delta_ number
---@field members_ table[]
---@field pending_ table[]
---@field ticking_ boolean
---@field dirty_ boolean
---@field stop_ boolean
---@field drop_ boolean
---@field skip_ boolean
---@field after_ (fun(dt:number,line:SumeruTimeline))?
---@field serial_ integer
---@field steps_ integer
local Timeline={};Timeline.__index=Timeline

-- 积攒时间与步长比较时的容差，避免浮点误差让刚好攒满的一步拖到下一帧。
local EPSILON=1e-9

-- 创建时间线：step 为固定步长（缺省每帧一次），maxDelta 为单帧真实时间上限（缺省 0.25 秒），maxSteps 为单帧最多步数（缺省不限）。
---@return SumeruTimeline
function Timeline.new(name,options)
 local self=setmetatable({},Timeline);self:init(name,options);return self
end

-- 初始化倍速、暂停原因、积攒时间与成员表。
function Timeline:init(name,options)
 options=options or {}
 assert(options.step==nil or options.step>0,"Timeline step must be positive")
 self.name=name;self.step=options.step;self.maxDelta=options.maxDelta or .25;self.maxSteps=options.maxSteps
 self.scale_=1;self.holds_={};self.holdCount_=0;self.acc_=0;self.time_=0;self.delta_=0
 self.members_={};self.pending_={};self.ticking_=false;self.dirty_=false;self.stop_=false;self.drop_=false;self.skip_=false
 self.after_=nil;self.serial_=0;self.steps_=0
end

-- 成员排序：priority 小的先执行，同级按加入顺序。
local function before(a,b)
 if a.priority~=b.priority then return a.priority<b.priority end
 return a.order<b.order
end

-- 查找成员条目（含执行中途待加入的），只返回仍有效的条目。
local function find(list,target)
 for i=1,#list do local e=list[i];if e.alive and e.target==target then return e end end
end

-- 加入成员：target 为函数或带 Tick 方法的表，priority 缺省 0；重复加入直接返回。执行中途加入的成员从下一步开始执行。
---@param target SumeruTickTarget
---@param priority number?
function Timeline:Add(target,priority)
 assert(type(target)=="function" or (type(target)=="table" and type(target.Tick)=="function"),"Timeline member needs a function or :Tick")
 if find(self.members_,target) or find(self.pending_,target) then return target end
 self.serial_=self.serial_+1
 local entry={target=target,priority=priority or 0,order=self.serial_,alive=true}
 if self.ticking_ then self.pending_[#self.pending_+1]=entry else self:insert_(entry) end
 return target
end

-- 按执行顺序插入成员表。
function Timeline:insert_(entry)
 local list=self.members_;local i=#list
 while i>0 and before(entry,list[i]) do list[i+1]=list[i];i=i-1 end
 list[i+1]=entry
end

-- 移除成员：立即停止调用它；执行中途移除的条目在这一步结束后清理。
---@param target SumeruTickTarget
function Timeline:Remove(target)
 local e=find(self.members_,target) or find(self.pending_,target)
 if not e then return false end
 e.alive=false;self.dirty_=true
 if not self.ticking_ then self:compact_() end
 return true
end

-- 移除全部成员，倍速、暂停原因和计时保持不变。
function Timeline:Clear()
 for _,e in ipairs(self.members_) do e.alive=false end
 for _,e in ipairs(self.pending_) do e.alive=false end
 self.members_={};self.pending_={};self.dirty_=false
end

-- 清理已移除的条目，并把执行中途加入的成员按顺序并入成员表。
function Timeline:compact_()
 if self.dirty_ then
  local list,kept=self.members_,0
  for i=1,#list do local e=list[i];if e.alive then kept=kept+1;list[kept]=e end end
  for i=#list,kept+1,-1 do list[i]=nil end
  self.dirty_=false
 end
 if #self.pending_>0 then
  local pending=self.pending_;self.pending_={}
  for _,e in ipairs(pending) do if e.alive then self:insert_(e) end end
 end
end

-- 设置倍速（不小于 0）：只改之后积攒时间的速度，已积攒的时间不变。
function Timeline:SetScale(scale)
 assert(type(scale)=="number" and scale>=0,"Timeline scale must be >= 0")
 self.scale_=scale
end
-- 当前倍速。
function Timeline:Scale() return self.scale_ end

-- 按原因暂停并丢弃积攒时间；同一原因重复调用只算一次。
---@param reason string
function Timeline:Hold(reason)
 if not self.holds_[reason] then self.holds_[reason]=true;self.holdCount_=self.holdCount_+1 end
 self.acc_=0
end
-- 解除一个暂停原因；全部原因都解除后恢复推进。
---@param reason string
function Timeline:Release(reason)
 if self.holds_[reason] then self.holds_[reason]=nil;self.holdCount_=self.holdCount_-1 end
end
-- 按条件开关一个暂停原因，适合每帧根据状态同步。
---@param reason string
---@param on boolean
function Timeline:SetHold(reason,on)
 if on then self:Hold(reason) else self:Release(reason) end
end
-- 是否有任何暂停原因。
function Timeline:Paused() return self.holdCount_>0 end
-- 指定原因当前是否在暂停这条时间线。
---@param reason string
function Timeline:Held(reason) return self.holds_[reason]==true end
-- 当前全部暂停原因，按名称排序，供调试面板和界面文案读取。
---@return string[]
function Timeline:Holds()
 local list={}
 for reason in pairs(self.holds_) do list[#list+1]=reason end
 table.sort(list);return list
end

-- 丢弃积攒时间，恢复运行时调用，避免把停顿期间的时间一次补回来。
function Timeline:Reset() self.acc_=0 end

-- 在成员或收尾回调里调用：本帧不再执行后面的步数（当前这一步的剩余成员是否继续由 Skip 决定）；drop 为真时同时丢弃剩余积攒时间。
---@param drop boolean?
function Timeline:Interrupt(drop)
 self.stop_=true;if drop then self.drop_=true end
end
-- 在成员里调用：跳过这一步剩下的成员，收尾回调照常执行；后面的步数照常推进，需要停在这一帧再配合 Interrupt。
function Timeline:Skip() if self.ticking_ then self.skip_=true end end
-- 设置每步收尾回调 fn(dt,line)：每执行完一步（含被 Skip 跳过剩余成员的步）调用一次，适合做存档、界面同步和决定是否 Interrupt；传 nil 取消。
---@param fn (fun(dt:number,line:SumeruTimeline))?
function Timeline:AfterStep(fn) self.after_=fn end

-- 累计推进的缩放后时间（秒）。
function Timeline:Time() return self.time_ end
-- 上一帧推进的缩放后时间（秒），暂停或没攒够一步时为 0。
function Timeline:Delta() return self.delta_ end

-- 用 dt 执行一步：按顺序调用成员，遇到 Skip 跳过剩余成员，最后调用收尾回调；执行中途的增删在这一步结束后生效。
function Timeline:run_(dt)
 self.ticking_=true;self.skip_=false
 local list=self.members_
 for i=1,#list do
  local e=list[i]
  if e.alive then
   local target=e.target
   if type(target)=="function" then target(dt,self) else target:Tick(dt,self) end
   if self.skip_ then break end
  end
 end
 self.skip_=false
 local after=self.after_;if after then after(dt,self) end
 self.ticking_=false
 self:compact_()
 self.time_=self.time_+dt;self.delta_=self.delta_+dt;self.steps_=self.steps_+1
end

-- 推进一帧：暂停时丢弃积攒时间；真实时间先截断到 maxDelta 再乘倍速。固定步长时攒够一步执行一步，
-- 遇到 Interrupt、成员中途暂停或达到 maxSteps 就停在这一帧；可变步长时直接执行一次。
---@param dt number
function Timeline:Advance(dt)
 self.delta_=0
 if self.holdCount_>0 then self.acc_=0;return end
 local frame=math.min(math.max(0,dt or 0),self.maxDelta)*self.scale_
 if frame<=0 then return end
 local step=self.step
 if not step then self:run_(frame);self.stop_=false;self.drop_=false;return end
 self.acc_=self.acc_+frame
 local count=0
 while self.acc_+EPSILON>=step do
  self.acc_=math.max(0,self.acc_-step);count=count+1
  self:run_(step)
  if self.holdCount_>0 or self.drop_ then self.acc_=0;break end
  if self.stop_ then break end
  if self.maxSteps and count>=self.maxSteps then self.acc_=0;break end
 end
 self.stop_=false;self.drop_=false
end

-- 立即执行 count 步（缺省 1），不受暂停和倍速影响、不动积攒时间，用于调试单步；固定步长时每步用 step，否则用 dt。
-- 不能在成员里调用；遇到 Interrupt 就停下。
---@param count integer?
---@param dt number?
function Timeline:Step(count,dt)
 assert(not self.ticking_,"Timeline:Step cannot run inside a member")
 local size=self.step or dt or 0
 if size<=0 then return end
 for _=1,count or 1 do
  self:run_(size)
  if self.stop_ then break end
 end
 self.stop_=false;self.drop_=false
end

-- 统计：成员数、倍速、是否暂停与暂停原因、累计时间与累计步数，供调试面板低频读取。
function Timeline:Stats()
 local members=0
 for _,e in ipairs(self.members_) do if e.alive then members=members+1 end end
 return {name=self.name,members=members,scale=self.scale_,paused=self.holdCount_>0,holds=self:Holds(),time=self.time_,steps=self.steps_}
end
return Timeline
