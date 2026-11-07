-- 更新调度 System：按名称登记时间线，入口每帧调用一次 Update，按创建顺序推进全部时间线；经 Architecture:RegisterSystem("TickKit") 管理。
local Timeline=require("sumeru.toolkit.tickkit.Timeline")
---@class SumeruTickKit
---@field lines_ table<string,SumeruTimeline>
---@field order_ SumeruTimeline[]
---@field updating_ boolean
---@field dirty_ boolean
local Kit={};Kit.__index=Kit

-- 创建独立的时间线登记表；一个架构通常只注册一个实例。
---@return SumeruTickKit
function Kit.new()
 local self=setmetatable({},Kit);self:init();return self
end

-- 初始化空登记表。
function Kit:init() self.lines_={};self.order_={};self.updating_=false;self.dirty_=false end

-- 取或建时间线：同名已存在时直接返回，选项只在首次创建时生效。新建的时间线排在已有时间线之后推进。
---@return SumeruTimeline
function Kit:Timeline(name,options)
 ---@type SumeruTimeline?
 local found=self.lines_[name]
 if found then return found end
 local line=Timeline.new(name,options);self.lines_[name]=line;self.order_[#self.order_+1]=line
 return line
end

-- 按名称查询时间线，不存在时返回 nil。
function Kit:Get(name) return self.lines_[name] end

-- 注销时间线并移除全部成员；在 Update 过程中注销时，本帧结束后再从推进顺序里删掉。
function Kit:Release(name)
 local line=self.lines_[name];if not line then return end
 self.lines_[name]=nil;line:Clear()
 if self.updating_ then self.dirty_=true;return end
 for i=#self.order_,1,-1 do if self.order_[i]==line then table.remove(self.order_,i) end end
end

-- 推进一帧：按创建顺序推进全部时间线，dt 为本帧真实时间（秒）。
---@param dt number
function Kit:Update(dt)
 self.updating_=true
 local order=self.order_
 for i=1,#order do local line=order[i];if self.lines_[line.name]==line then line:Advance(dt) end end
 self.updating_=false
 if self.dirty_ then
  self.dirty_=false
  for i=#order,1,-1 do if self.lines_[order[i].name]~=order[i] then table.remove(order,i) end end
 end
end

-- 汇总全部时间线的统计，按创建顺序；供调试面板低频读取。
function Kit:Stats()
 local rows={}
 for _,line in ipairs(self.order_) do if self.lines_[line.name]==line then rows[#rows+1]=line:Stats() end end
 return rows
end
return Kit
