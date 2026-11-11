-- sumeru 类型事件总线：按事件 key 订阅/派发，支持对象级批量解绑。
-- 对应 QFramework 的 TypeEventSystem；Lua 无泛型，用字符串 key 代替事件类型。
-- Fire 当场派发；Post 先入队，由主循环每帧调一次 Drain 按序派发（监听者不会插进一个动作的半路）。
---@class SumeruTypeEvent
---@field handlers_ table<string,SumeruEventHandler[]>
---@field queue_ table<integer,table>
---@field head_ integer
---@field tail_ integer
---@field draining_ boolean
---@field strict boolean 监听者报错时重新抛出（测试用，默认只打印）
---@field trace boolean 打印每次派发（排查谁发了什么）
local TypeEvent={}
TypeEvent.__index=TypeEvent

-- 一次 Drain 最多派发多少个事件：监听者互相 Post 成死循环时，剩下的留到下一帧。
local MAX_DRAIN_=1000

-- key 拼错（比如常量写错成 nil）时当场报错，不要静默什么都不发生。
local function checkKey(key)
 if type(key)~="string" or key=="" then
  error("[sumeru] TypeEvent 的 key 必须是非空字符串，实际是 "..tostring(key),3)
 end
end

-- 创建空总线。
---@return SumeruTypeEvent
function TypeEvent.new()
 local self=setmetatable({},TypeEvent)
 self.handlers_={}
 self.queue_={};self.head_=1;self.tail_=1
 self.draining_=false
 self.strict=false
 self.trace=false
 return self
end

-- 订阅事件：On(key, fn) 或 On(key, owner, fn)。
-- 带 owner 的订阅可被 OffAll(owner) 批量解绑；fn 建议用闭包捕获 owner 自身。
function TypeEvent:On(key,a,b)
 checkKey(key)
 local owner,fn
 if b==nil then owner=false;fn=a else owner=a;fn=b end
 if type(fn)~="function" then error("[sumeru] TypeEvent:On 需要 function 处理器",2) end
 local list=self.handlers_[key]
 if not list then list={};self.handlers_[key]=list end
 list[#list+1]={owner=owner,fn=fn}
end

-- 解绑指定订阅（owner 与 fn 需与 On 时一致）。
function TypeEvent:Off(key,a,b)
 local owner,fn
 if b==nil then owner=false;fn=a else owner=a;fn=b end
 local list=self.handlers_[key]
 if not list then return end
 for i=#list,1,-1 do
  if list[i].owner==owner and list[i].fn==fn then table.remove(list,i) end
 end
 if #list==0 then self.handlers_[key]=nil end
end

-- 解绑某 owner 通过 On(key, owner, fn) 注册过的全部事件。
function TypeEvent:OffAll(owner)
 for key,list in pairs(self.handlers_) do
  for i=#list,1,-1 do
   if list[i].owner==owner then table.remove(list,i) end
  end
  if #list==0 then self.handlers_[key]=nil end
 end
end

-- 调一个监听者：报错只影响它自己，发送方和后面的监听者照常（strict 时重新抛出）。
function TypeEvent:call_(key,fn,...)
 local ok,err=xpcall(fn,debug.traceback,...)
 if ok then return end
 print("[sumeru] 事件 "..key.." 的监听者报错："..tostring(err))
 if self.strict then error(err,0) end
end

-- 当场派发：快照遍历并校验订阅仍存活，允许回调中增删订阅。
function TypeEvent:Fire(key,...)
 checkKey(key)
 if self.trace then print("[sumeru] event "..key) end
 local list=self.handlers_[key]
 if not list then return end
 local snapshot={}
 for i=1,#list do snapshot[i]=list[i] end
 for i=1,#snapshot do
  local h=snapshot[i]
  local alive=false
  local current=self.handlers_[key]
  if current then
   for j=1,#current do if current[j]==h then alive=true;break end end
  end
  if alive then self:call_(key,h.fn,...) end
 end
end

-- 入队，等 Drain 时再派发：业务系统报告“发生了什么”用这个。
function TypeEvent:Post(key,...)
 checkKey(key)
 self.queue_[self.tail_]=table.pack(key,...)
 self.tail_=self.tail_+1
end

-- 队列里还有几个事件没派发。
---@return integer
function TypeEvent:Pending()
 return self.tail_-self.head_
end

-- 丢掉还没派发的事件（开新局、读档时用）。
function TypeEvent:ClearQueue()
 self.queue_={};self.head_=1;self.tail_=1
end

function TypeEvent:drainLoop_(limit)
 local count=0
 while self.head_<self.tail_ and count<limit do
  local e=self.queue_[self.head_]
  self.queue_[self.head_]=nil
  self.head_=self.head_+1
  count=count+1
  self:Fire(table.unpack(e,1,e.n))
 end
 if self.head_<self.tail_ then
  print(string.format("[sumeru] Drain 到上限 %d，还剩 %d 个事件留到下一帧（监听者是不是在互相 Post？）",limit,self:Pending()))
 else
  self.queue_={};self.head_=1;self.tail_=1
 end
 return count
end

-- 按入队顺序派发；派发中新 Post 的事件这次一起处理。重入时什么都不做，返回派发了几个。
---@param limit integer|nil 这次最多派发几个
---@return integer
function TypeEvent:Drain(limit)
 if self.draining_ then return 0 end
 self.draining_=true
 local ok,result=pcall(self.drainLoop_,self,limit or MAX_DRAIN_)
 self.draining_=false
 if not ok then error(result,0) end
 return result
end
return TypeEvent

---@class SumeruEventHandler
---@field owner any
---@field fn fun(...:any)
