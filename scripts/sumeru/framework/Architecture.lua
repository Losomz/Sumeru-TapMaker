-- sumeru 架构：具名单例 + IOC 容器 + 事件总线 + 能力注入。
-- 对应 QFramework 的 Architecture<T>：Model（数据）/System（功能）/Utility（工具）
-- 经容器注册解析；Inject 为任意对象补上 ICanGet*/ICanSendEvent/ICanRegisterEvent 能力。
local Container=require("sumeru.framework.Container")
local TypeEvent=require("sumeru.framework.TypeEvent")

---@class SumeruArchitecture
---@field name string
---@field container SumeruContainer
---@field events SumeruTypeEvent
local Architecture={}
Architecture.__index=Architecture

local architectures_={}

-- 创建或取回具名架构单例（同名重复调用返回同一实例）。
function Architecture.MakeArchitecture(name)
 local arch=architectures_[name]
 if not arch then arch=Architecture.new(name);architectures_[name]=arch end
 return arch
end

-- 清除全部具名架构（测试或重启用）。
function Architecture.Reset()
 architectures_={}
end

-- 创建架构实例；一般经由 MakeArchitecture 获取。
---@return SumeruArchitecture
function Architecture.new(name)
 local self=setmetatable({},Architecture)
 self.name=name;self.container=Container.new(self);self.events=TypeEvent.new()
 return self
end

-- 注册 Model（数据层）：实例或 function(arch) 工厂；解析后注入能力并调用 OnInit。
function Architecture:RegisterModel(key,value)
 return self:register_("model",key,value)
end

-- 注册 System（功能层）：实例或工厂；UIKit 等 toolkit 模块经此挂载。
function Architecture:RegisterSystem(key,value)
 return self:register_("system",key,value)
end

-- 注册 Utility（工具层）：实例或工厂。
function Architecture:RegisterUtility(key,value)
 return self:register_("utility",key,value)
end

-- 统一注册：实例注册即时注入并触发 OnInit（注册完即可静态使用，UIKit 静态入口依赖此行为）；
-- 工厂注册保持惰性，首次 Get 时才求值、注入并触发 OnInit。
function Architecture:register_(kind,key,value)
 local arch=self
 if type(value)=="function" then
  arch.container:Register(key.."@"..kind,function()
   local v=value(arch)
   if type(v)=="table" then
    arch:Inject(v)
    if type(v.OnInit)=="function" then v:OnInit() end
   end
   return v
  end)
  return value
 end
 arch:Inject(value)
 if type(value)=="table" and type(value.OnInit)=="function" then value:OnInit() end
 arch.container:Register(key.."@"..kind,function() return value end)
 return value
end

-- 查询 Model/System/Utility（同 key 多种类注册时以 @kind 命名空间隔离）。
function Architecture:GetModel(key) return self.container:Get(key.."@model") end
function Architecture:GetSystem(key) return self.container:Get(key.."@system") end
function Architecture:GetUtility(key) return self.container:Get(key.."@utility") end

-- 能力注入：为对象挂上架构引用与 ICan* 能力方法（不覆盖已有同名方法）。
-- 注入后可用 obj:GetModel(k) / obj:GetSystem(k) / obj:GetUtility(k) /
-- obj:SendEvent(k,...)（当场派发）/ obj:PostEvent(k,...)（入队，等 Drain）/ obj:RegisterEvent(k,fn) / obj:UnRegisterEvent(k,fn) / obj:UnRegisterAllEvent()。
function Architecture:Inject(obj)
 if type(obj)~="table" or obj.arch~=nil then return obj end
 local arch=self
 obj.arch=arch
 obj.GetModel=obj.GetModel or function(_,key) return arch:GetModel(key) end
 obj.GetSystem=obj.GetSystem or function(_,key) return arch:GetSystem(key) end
 obj.GetUtility=obj.GetUtility or function(_,key) return arch:GetUtility(key) end
 obj.SendEvent=obj.SendEvent or function(_,key,...) arch.events:Fire(key,...) end
 obj.PostEvent=obj.PostEvent or function(_,key,...) arch.events:Post(key,...) end
 obj.RegisterEvent=obj.RegisterEvent or function(_,key,fn) arch.events:On(key,obj,fn) end
 obj.UnRegisterEvent=obj.UnRegisterEvent or function(_,key,fn) arch.events:Off(key,obj,fn) end
 obj.UnRegisterAllEvent=obj.UnRegisterAllEvent or function() arch.events:OffAll(obj) end
 obj.GetArchitecture=obj.GetArchitecture or function() return arch end
 return obj
end
return Architecture
