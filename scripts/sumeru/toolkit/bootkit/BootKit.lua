-- 游戏启动 toolkit：框架初始化 → 首屏包下载（LoadKit）→ 游戏内容加载（插槽）→ 交给游戏，期间显示启动页。
-- 只依赖 urhox-libs/UI，不依赖 UIKit。游戏内的分包下载、进页面前的加载提示归 LoadKit 和游戏自己，不归这里。
local UI=require("urhox-libs/UI")
local Screen=require("sumeru.toolkit.bootkit.BootScreen")

---@class SumeruBootText
---@field phrases string[]? 轮换短句
---@field phraseEvery number? 短句几秒一换
---@field tips string[]? 轮换小提示
---@field tipEvery number? 小提示几秒一换
---@field tipPrefix string? 小提示前缀
---@field errorColor number[]? 失败文案字色
---@field messages {retrying:string?,failed:string?,step:string?}? 自动重试中 / 下载失败（%d 为失败项数）/ 内容步骤失败的默认文案

---@class SumeruBootStepDef
---@field label string 步骤名，用于日志和埋点
---@field weight number? 在内容段进度里的占比，默认 1
---@field start fun(step:SumeruBootStep)? 开始时调用一次
---@field update fun(step:SumeruBootStep,dt:number)? 没做完时每帧调用

---@class SumeruBootOptions
---@field ui table? 传给 UI.Init 的参数；游戏已自己初始化 UI 时不传
---@field setup fun(kit:SumeruBootKit):table? 框架初始化：注册样式、控件、架构、分包等，返回 LoadKit
---@field loads table? 不在 setup 里返回时直接给 LoadKit
---@field layout string? 项目的启动页布局；不给或读不到时用框架默认模板
---@field text SumeruBootText?
---@field packs string[]? 首屏包，按顺序下载
---@field prefetch string[]? 启动完成后后台预取的包
---@field downloadShare number? 下载段占进度条的比例，默认 0.85（没有内容步骤时为 1）
---@field steps SumeruBootStepDef[]? 游戏内容加载插槽，首屏包下完后依次执行
---@field onDone fun(kit:SumeruBootKit)? 全部完成后调用一次
---@field onEvent fun(name:string,data:table)? begin / auto_retry / fail / retry / ready，供游戏埋点

---@class SumeruBootStep
---@field kit SumeruBootKit
---@field def SumeruBootStepDef
---@field label string
---@field k number 本步进度 0..1
---@field alive boolean
local Step={};Step.__index=Step
-- 报告本步进度（0..1）。
function Step:Progress(k) if self.alive then self.k=math.max(0,math.min(1,tonumber(k) or 0)) end end
-- 本步完成；下一步从下一帧开始，让启动页先画一帧。
function Step:Done() if self.alive then self.alive=false;self.k=1;self.kit:stepDone_(self) end end
-- 本步失败：显示文案和重试按钮，点重试从这一步重新开始。
function Step:Fail(text) if self.alive then self.alive=false;self.kit:stepFail_(self,text) end end

---@class SumeruBootKit
---@field opt SumeruBootOptions
---@field text SumeruBootText
---@field state string new / downloading / content / failed / done
---@field loads table|nil
---@field screen table|nil
---@field elapsed number 启动以来的秒数（按帧累计）
---@field download number 下载段进度 0..1
---@field retrying boolean 自动重试后还没有新进度
---@field retries integer 自动重试次数
---@field manual integer 玩家手动重试次数
---@field stepIndex integer
---@field step SumeruBootStep|nil
---@field failStage string|nil
---@field message string|nil
local Kit={};Kit.__index=Kit
Kit.LAYOUT="sumeru/toolkit/bootkit/boot.ui.json"
---@type SumeruBootText
Kit.TEXT={phrases={"正在启动…"},phraseEvery=1.6,tips={},tipEvery=6,tipPrefix="小提示：",errorColor={220,140,120,255},
 messages={retrying="网络不太稳，正在重试…",failed="有 %d 项素材没下载成功，请检查网络后重试。",step="启动出错了，请重试。"}}

-- 合并文案配置：messages 逐项覆盖，其余按项覆盖。
local function mergeText(cfg)
 local t={};for k,v in pairs(Kit.TEXT) do t[k]=v end
 for k,v in pairs(cfg or {}) do if k~="messages" then t[k]=v end end
 t.messages={};for k,v in pairs(Kit.TEXT.messages or {}) do t.messages[k]=v end
 for k,v in pairs((cfg or {}).messages or {}) do t.messages[k]=v end
 return t
end

-- 创建启动流程；调用 Start 才开始。
---@param opt SumeruBootOptions
---@return SumeruBootKit
function Kit.new(opt)
 opt=opt or {}
 local self=setmetatable({opt=opt,text=mergeText(opt.text),state="new",elapsed=0,download=0,retrying=false,
  retries=0,manual=0,stepIndex=1,step=nil,failStage=nil,message=nil},Kit)
 return self
end

-- 埋点回调出错只打印，不影响启动。
function Kit:emit_(name,data)
 if not self.opt.onEvent then return end
 local ok,err=pcall(self.opt.onEvent,name,data or {})
 if not ok then print("[BootKit] onEvent 出错："..tostring(err)) end
end

-- 开始启动：UI.Init → 游戏 setup → 显示启动页 → 下载首屏包。
function Kit:Start()
 if self.state~="new" then return end
 if self.opt.ui then UI.Init(self.opt.ui) end
 local loads=self.opt.setup and self.opt.setup(self)
 self.loads=loads or self.opt.loads
 self.screen=Screen.new(self,self.opt.layout)
 print("[BootKit] 启动页已显示")
 self:emit_("begin",{})
 self:download_()
end

-- 下载首屏包；没有 LoadKit 或没有首屏包时直接进内容段。
function Kit:download_()
 local packs=self.opt.packs or {}
 if not self.loads or #packs==0 then self.download=1;return self:content_() end
 self.state="downloading"
 -- 先告诉 LoadKit 有人每帧推进：失败按 backoff 等待再重试，卡住检测也生效。
 if self.loads.Update then self.loads:Update(0) end
 self.loads:Ensure(packs,{
  onProgress=function(done,total)
   local k=done/math.max(1,total)
   if k>self.download then self.retrying=false end
   self.download=k
  end,
  onRetry=function(pack,attempt)
   self.retries=self.retries+1;self.retrying=true
   self:emit_("auto_retry",{pack=pack,attempt=attempt})
  end,
  onReady=function() self.download=1;self.retrying=false;print("[BootKit] 首屏包就绪："..table.concat(packs,","));self:content_() end,
  onFail=function(n) self:fail_("download",string.format(self.text.messages.failed,n),n) end,
 })
end

-- 进入游戏内容段：步骤在 Update 里逐个开始。
function Kit:content_()
 self.state="content";self.step=nil
end

-- 第 i 步之前所有步骤的权重和与总权重。
function Kit:weights_()
 local before,total=0,0
 for i,def in ipairs(self.opt.steps or {}) do
  local w=math.max(0,tonumber(def.weight) or 1)
  if i<self.stepIndex then before=before+w end
  total=total+w
 end
 return before,total
end

-- 整体进度 0..1：下载段占 downloadShare，内容段按步骤权重分。
function Kit:Progress()
 if self.state=="done" then return 1 end
 local steps=self.opt.steps or {}
 local share=#steps==0 and 1 or math.max(0,math.min(1,self.opt.downloadShare or .85))
 if #(self.opt.packs or {})==0 or not self.loads then share=0 end
 local p=share*self.download
 if #steps>0 then
  local before,total=self:weights_()
  local cur=0
  if self.step then cur=self.step.k*math.max(0,tonumber(self.step.def.weight) or 1) end
  if total>0 then p=p+(1-share)*(before+cur)/total end
 end
 return math.max(0,math.min(1,p))
end

-- 首屏第一个包是否就绪（启动页图标的图通常放在这个包里）。
function Kit:FirstPackReady()
 local first=(self.opt.packs or {})[1]
 if not first or not self.loads then return true end
 return self.loads:IsReady(first)
end

-- 启动是否已完成（onDone 已调用）。
function Kit:IsDone() return self.state=="done" end
-- 当前状态：new / downloading / content / failed / done。
function Kit:State() return self.state end

-- 每帧调用。启动期间驱动 LoadKit:Update、内容步骤和启动页；完成后不再推进 LoadKit（交给游戏），
-- 只在启动页被游戏的 UI 根节点替换后释放引用。
---@param dt number
function Kit:Update(dt)
 if self.state=="new" then return end
 if self.state=="done" then
  if self.screen and self.screen:Detached() then self.screen:Forget();self.screen=nil end
  return
 end
 dt=math.max(0,dt or 0)
 self.elapsed=self.elapsed+dt
 if self.loads and self.loads.Update then self.loads:Update(dt) end
 if self.state=="content" then self:runStep_(dt) end
 if self.screen then self.screen:Update(dt) end
end

-- 开始下一步或推进当前步；步骤报错按失败处理并打印堆栈。
function Kit:runStep_(dt)
 local steps=self.opt.steps or {}
 if not self.step then
  local def=steps[self.stepIndex]
  if not def then return self:finish_() end
  local step=setmetatable({kit=self,def=def,label=def.label or ("step"..self.stepIndex),k=0,alive=true},Step)
  self.step=step
  print("[BootKit] 开始："..step.label)
  if def.start then
   local ok,err=xpcall(def.start,debug.traceback,step)
   if not ok then print("[BootKit] "..step.label.." 出错："..tostring(err));step:Fail() end
  elseif not def.update then step:Done() end
  return
 end
 local step=self.step
 if step.alive and step.def.update then
  local ok,err=xpcall(step.def.update,debug.traceback,step,dt)
  if not ok then print("[BootKit] "..step.label.." 出错："..tostring(err));step:Fail() end
 end
end

-- 一步完成：记下进度，下一帧开始下一步。
function Kit:stepDone_(step)
 if self.step~=step then return end
 print("[BootKit] 完成："..step.label)
 self.stepIndex=self.stepIndex+1;self.step=nil
end

-- 一步失败：停在这一步，等玩家重试。
function Kit:stepFail_(step,text)
 if self.step~=step then return end
 self.step=nil
 self:fail_(step.label,text or self.text.messages.step,0)
end

-- 进入失败态并上报。
function Kit:fail_(stage,text,failed)
 self.state="failed";self.failStage=stage;self.message=text;self.retrying=false
 print("[BootKit] 失败（"..stage.."）："..tostring(text))
 self:emit_("fail",{stage=stage,failed=failed or 0,retries=self.retries,sec=math.floor(self.elapsed*10+.5)/10})
end

-- 玩家点重试：下载失败只重下失败的批次；内容步骤失败从那一步重新开始。
function Kit:Retry()
 if self.state~="failed" then return false end
 self.manual=self.manual+1;self.message=nil
 self:emit_("retry",{manual=self.manual})
 print("[BootKit] 第 "..self.manual.." 次手动重试："..tostring(self.failStage))
 if self.failStage=="download" then
  self.state="downloading"
  if not self.loads:Retry() then self:download_() end
 else
  self:content_()
 end
 return true
end

-- 全部完成：上报、后台预取、交给游戏。启动页留到游戏的 UI 根节点替换它（UIKit 首次刷新时会替换并销毁）。
function Kit:finish_()
 self.state="done"
 local sec=math.floor(self.elapsed*10+.5)/10
 print(string.format("[BootKit] 启动完成，用时 %.1f 秒，自动重试 %d 次，手动重试 %d 次",sec,self.retries,self.manual))
 if self.screen then self.screen:Update(0) end
 self:emit_("ready",{sec=sec,retries=self.retries,manual=self.manual})
 if self.loads and self.opt.prefetch and #self.opt.prefetch>0 then self.loads:Prefetch(self.opt.prefetch) end
 if self.opt.onDone then self.opt.onDone(self) end
end

-- 不用 UIKit 的项目在 onDone 之后调用：启动页还挂在 UI 根上时把它卸掉。
function Kit:Release()
 if self.screen then self.screen:Destroy();self.screen=nil end
end

return Kit
