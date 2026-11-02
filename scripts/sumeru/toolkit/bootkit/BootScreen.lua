-- 启动页控制器：读启动页布局（项目可换成自己的 .ui.json，读不到用框架默认模板），按约定 id 刷新画面。
-- 逻辑固定、样式在布局里：底色、字体、字号、颜色、位置、按钮外观都写在布局里，换样式不用改代码。
-- 约定 id（除 boot-root 外都可以删）：
--   boot-root      全屏底
--   boot-icon      图标位，任意控件；每帧写入 props.progress（0..100）、props.ready（首包是否就绪），有 Tick(dt) 就调用
--   boot-bar       进度条槽；boot-bar-fill 为填充，按进度设宽度百分比
--   boot-percent   百分比文字
--   boot-phrase    轮换短句；自动重试时显示重试提示，失败时显示失败文案（换成 errorColor）
--   boot-tip       轮换小提示，失败时隐藏
--   boot-button    失败时显示，点了重试；布局里没有时点全屏任意处重试
local UI=require("urhox-libs/UI")
local Screen={};Screen.__index=Screen
Screen.IDS={"boot-icon","boot-bar","boot-bar-fill","boot-percent","boot-phrase","boot-tip","boot-button"}
local FADE=.25

-- 读布局：先读项目的，读不到再读框架默认模板。
local function load(path,fallback)
 if path and path~=fallback then
  local instance,err=UI.LoadJSON(path)
  if instance then return instance,path end
  print("[BootKit] 启动页布局读不到，改用框架默认模板："..tostring(path).."（"..tostring(err).."）")
 end
 local instance,err=UI.LoadJSON(fallback)
 if not instance then print("[BootKit] 框架默认启动页也读不到："..tostring(err)) end
 return instance,fallback
end

local function copyColor(c) if type(c)=="table" then return {c[1] or 255,c[2] or 255,c[3] or 255,c[4] or 255} end end
-- 淡入淡出：每段开头 FADE 秒淡入、结尾 FADE 秒淡出；透明度量化到 16 级，避免每帧重排。
local function fade(t,every)
 local a=math.min(1,t/FADE,(every-t)/FADE);return math.floor(math.max(0,a)*16+.5)/16
end
local function alpha(c,a) return {c[1],c[2],c[3],math.floor((c[4] or 255)*a)} end
-- 文字和颜色只在变化时写入。
local function setText(label,text,color)
 if not label then return end
 text=tostring(text or "")
 if label.bootText_~=text then label:SetText(text);label.bootText_=text end
 if color then
  local key=table.concat(color,",")
  if label.bootColor_~=key then label:SetStyle({fontColor=color});label.bootColor_=key end
 end
end
local function show(widget,visible)
 if widget and widget:IsVisible()~=visible then widget:SetVisible(visible) end
end

-- 创建启动页并挂到 UI 根上。
---@param kit SumeruBootKit
---@param layout string|nil
function Screen.new(kit,layout)
 local self=setmetatable({kit=kit,w={},shown=0,barKey=nil,pi=1,pt=0,ti=1,tt=0},Screen)
 local instance,path=load(layout,kit.LAYOUT)
 if not instance then return self end
 self.instance=instance;self.root=instance:GetRoot();self.path=path
 local missing={}
 for _,id in ipairs(Screen.IDS) do
  self.w[id]=instance:Find(id)
  if not self.w[id] then missing[#missing+1]=id end
 end
 if #missing>0 then print("[BootKit] 启动页 "..path.." 没有 "..table.concat(missing,"、").."，对应内容不显示") end
 local w=self.w
 self.phraseColor=copyColor(w["boot-phrase"] and w["boot-phrase"].props.fontColor) or {255,255,255,255}
 self.tipColor=copyColor(w["boot-tip"] and w["boot-tip"].props.fontColor) or {200,200,200,255}
 local tips=kit.text.tips or {}
 self.ti=#tips>0 and math.random(#tips) or 1
 -- 根节点挡住点击（启动期间没有可点的游戏画面）；没有按钮时点全屏重试。
 if self.root.props.pointerEvents==nil then self.root.props.pointerEvents="auto" end
 if w["boot-button"] then
  w["boot-button"].props.onClick=function() kit:Retry() end
  show(w["boot-button"],false)
 else
  self.root.props.onClick=function() if kit:State()=="failed" then kit:Retry() end end
 end
 if w["boot-bar-fill"] then w["boot-bar-fill"]:SetStyle({width="0%"}) end
 UI.SetRoot(self.root,false)
 return self
end

-- 每帧刷新：进度平滑追上，短句与小提示轮换，失败时换成失败文案与按钮。
function Screen:Update(dt)
 if not self.root then return end
 local kit,w,text=self.kit,self.w,self.kit.text
 local target=kit:Progress()*100
 self.shown=self.shown+(target-self.shown)*math.min(1,dt*6)
 if target-self.shown<.5 then self.shown=target end
 local icon=w["boot-icon"]
 if icon then
  icon.props.progress=target;icon.props.ready=kit:FirstPackReady()
  if icon.Tick then icon:Tick(dt) end
 end
 local key=math.floor(self.shown*2+.5)/2
 if self.barKey~=key then
  self.barKey=key
  if w["boot-bar-fill"] then w["boot-bar-fill"]:SetStyle({width=string.format("%.1f%%",key)}) end
  setText(w["boot-percent"],math.floor(key).."%")
 end
 local failed=kit:State()=="failed"
 show(w["boot-button"],failed)
 if failed then
  setText(w["boot-phrase"],kit.message or "",text.errorColor)
  show(w["boot-tip"],false)
  return
 end
 local phrases,tips=text.phrases or {},text.tips or {}
 show(w["boot-tip"],#tips>0)
 if kit.retrying then
  setText(w["boot-phrase"],text.messages.retrying,self.phraseColor)
 elseif #phrases>0 then
  local every=text.phraseEvery or 1.6
  self.pt=self.pt+dt;if self.pt>=every then self.pt=self.pt-every;self.pi=self.pi%#phrases+1 end
  setText(w["boot-phrase"],phrases[self.pi],alpha(self.phraseColor,#phrases>1 and fade(self.pt,every) or 1))
 end
 if #tips>0 then
  local every=text.tipEvery or 6
  self.tt=self.tt+dt;if self.tt>=every then self.tt=self.tt-every;self.ti=self.ti%#tips+1 end
  setText(w["boot-tip"],(text.tipPrefix or "")..tips[self.ti],alpha(self.tipColor,#tips>1 and fade(self.tt,every) or 1))
 end
end

-- 启动页是否已被游戏的 UI 根节点换下。
function Screen:Detached() return self.root~=nil and UI.GetRoot()~=self.root end
-- 已被别人销毁时只丢掉引用。
function Screen:Forget() self.root=nil;self.instance=nil;self.w={} end
-- 自己卸下：启动页还在 UI 根上时清空根并销毁；已被换下的由换它的人负责销毁。
function Screen:Destroy()
 if self.root and UI.GetRoot()==self.root then UI.SetRoot(nil,true) end
 self:Forget()
end

return Screen
