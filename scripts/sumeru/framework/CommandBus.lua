-- sumeru 命令中心：模块之间“请主人改它的数据”走这里。
-- 和事件中心（TypeEvent）的区别：
--   事件 = 通知“发生了什么”，发的人不管谁在听，可以没人听，也可以很多人听；
--   命令 = 请求“帮我改这个”，一个命令只有一个接收者（数据的主人），当场执行、带返回值。
-- 没人接、重复登记都当场报错；接收者报错原样抛给发命令的人（命令是同步调用，不吞错）。
---@class SumeruCommandBus
---@field handlers_ table<string,SumeruCommandHandler>
---@field sent_ table<string,integer>
---@field trace boolean 打印每次命令（排查谁在改什么）
local CommandBus={}
CommandBus.__index=CommandBus

-- key 拼错（比如常量写错成 nil）时当场报错。
local function checkKey(key)
 if type(key)~="string" or key=="" then
  error("[sumeru] CommandBus 的 key 必须是非空字符串，实际是 "..tostring(key),3)
 end
end

-- 创建空的命令中心。
---@return SumeruCommandBus
function CommandBus.new()
 local self=setmetatable({},CommandBus)
 self.handlers_={}
 self.sent_={}
 self.trace=false
 return self
end

-- 登记接收者：Handle(key, owner, fn)。一个 key 只能有一个接收者，已有就报错。
-- owner 是接收者对象（一般是数据的主人系统），用于 UnhandleAll 和查询。
function CommandBus:Handle(key,owner,fn)
 checkKey(key)
 if type(fn)~="function" then error("[sumeru] CommandBus:Handle 需要 function 处理器",2) end
 local old=self.handlers_[key]
 if old then
  error(string.format("[sumeru] 命令 %s 已经有接收者（%s），一个命令只能有一个",key,tostring(old.name)),2)
 end
 local name=type(owner)=="table" and (owner.NAME or owner.name) or nil
 self.handlers_[key]={owner=owner,fn=fn,name=name or tostring(owner)}
end

-- 撤掉 key 的接收者（owner 不对不撤）。
function CommandBus:Unhandle(key,owner)
 local h=self.handlers_[key]
 if h and h.owner==owner then self.handlers_[key]=nil end
end

-- 撤掉 owner 登记的全部命令。
function CommandBus:UnhandleAll(owner)
 for key,h in pairs(self.handlers_) do
  if h.owner==owner then self.handlers_[key]=nil end
 end
end

-- 发命令：当场交给接收者执行，返回它的全部返回值。没人接报错。
function CommandBus:Send(key,...)
 checkKey(key)
 local h=self.handlers_[key]
 if not h then error("[sumeru] 命令 "..key.." 没有接收者",2) end
 self.sent_[key]=(self.sent_[key] or 0)+1
 if self.trace then print("[sumeru] cmd "..key.." -> "..h.name) end
 return h.fn(...)
end

-- 有没有接收者。
---@return boolean
function CommandBus:Has(key)
 return self.handlers_[key]~=nil
end

-- 接收者对象（没有返回 nil）。
function CommandBus:Owner(key)
 local h=self.handlers_[key]
 return h and h.owner or nil
end

-- 全部已登记的 key（排好序）。
---@return string[]
function CommandBus:Keys()
 local out={}
 for key in pairs(self.handlers_) do out[#out+1]=key end
 table.sort(out)
 return out
end

-- key 发过几次（测试查“每个命令都用到了”）。
---@return integer
function CommandBus:Sent(key)
 return self.sent_[key] or 0
end

-- 发送计数清零。
function CommandBus:ResetCounts()
 self.sent_={}
end

return CommandBus

---@class SumeruCommandHandler
---@field owner any
---@field fn fun(...:any):...
---@field name string
