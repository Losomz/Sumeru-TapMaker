-- 单一 UI 根容器，独立 MainShell / GameShell / OverlayPanel 生命周期。
-- 业务约定：Attach(app,metrics) 的 app 可带 dirty 标记（为真时下一帧刷新全部可见页面）；
-- metrics(app) 返回 {w,h,vw,vh,safe={left,right},top,map,capsule,background}。
-- 业务画面框按 metrics 放在安全区内并裁剪；Backdrop() 是框下的全屏底层，供背景延伸到安全区外。
-- 宿主判定、面板路径与 Shell 组件由 Configure 注入，框架不引用任何业务模块。
local UI=require("urhox-libs/UI")
local Registry=require("sumeru.toolkit.uikit.PanelRegistry")
local Components=require("sumeru.toolkit.uikit.ComponentRegistry")
local PanelInstance=require("sumeru.toolkit.uikit.PanelInstance")
local Toast=require("sumeru.toolkit.uikit.toast.Toast")
---@class SumeruUIKitConfig
---@field host fun(app:table):string
---@field allows fun(def:SumeruPanelDefinition,app:table):boolean
---@field panelRoot string
---@field componentRoot string?
---@field shellComponents table<string,string[]>
---@field toast SumeruToastConfig|false|nil 内置提示的皮肤与样式覆盖；false 关闭内置提示

---@class SumeruUIKit
---@field active_ SumeruPanelInstance[]
---@field arch SumeruArchitecture?
---@field panels_ table<string,SumeruPanelDefinition>
---@field order_ SumeruPanelDefinition[]
---@field config_ SumeruUIKitConfig
---@field registry_ SumeruPanelRegistry
local Kit={}
Kit.Layers={Scene=0,HUD=10,Badge=15,PhasePage=20,Guide=30,Page=40,Popup=50,Toast=60}
-- 默认配置：始终使用 main 宿主、所有面板均允许、面板位于 ui/panels；Destroy 不清除配置。
Kit.config_={host=function() return "main" end,allows=function() return true end,panelRoot="ui/panels",componentRoot=nil,shellComponents={}}
-- 复制上下文，避免不同页面互相覆盖。
local function copy(source,target) for k,v in pairs(source or {}) do target[k]=v end;return target end
-- 初始化宿主状态；不影响业务模拟和存档。
local function reset()
 Kit.registry_=Registry.new(Kit.config_.panelRoot);Kit.panels_={};Kit.order_={};Kit.active_={};Kit.shells_={}
 Kit.pageKey_=false;Kit.overlayKey_=false;Kit.pageProps_={};Kit.openRevision_={}
 Kit.structureDirty_=true;Kit.dataDirty_=true;Kit.metricsKey_=nil;Kit.app_=nil
 Kit.noticeText_="";Kit.noticeTime_=0;Kit.noticeDuration_=0;Kit.noticeRevision_=0;Kit.noticeColor_=nil
 Kit.root_=nil;Kit.backdrop_=nil;Kit.frame_=nil;Kit.host_=nil;Kit.phaseResolver_=nil;Kit.metrics_=nil
end
-- 注入业务配置：host(app) 返回宿主 Shell 名，allows(def,app) 判断面板是否允许出现，
-- panelRoot 为面板约定根路径，componentRoot 为未登记组件的查找根路径，shellComponents 为各 Shell 预加载组件，
-- toast 为内置提示的底图、文字与样式覆盖（false 关闭）。需在 RegisterPanel 之前调用，未传字段保持原值。
function Kit:Configure(opts)
 copy(opts,self.config_)
 self.registry_:SetRoot(self.config_.panelRoot)
 Components:SetRoot(self.config_.componentRoot)
 self:MarkStructureDirty()
end
-- 挂接 App 和自适应测量函数；内置提示未关闭时注册在 overlay 宿主的 Toast 层。
function Kit:Attach(app,metrics)
 self.app_=app;self.metrics_=metrics
 if self.config_.toast~=false and not self.panels_[Toast.KEY] then
  self:RegisterPanel(Toast.KEY,{shell="overlay",owner="global",layer=self.Layers.Toast,template=Toast.TEMPLATE,controller=Toast.CONTROLLER,
   visible=function(_,kit) return kit:HasNotice() end})
 end
 self:MarkStructureDirty()
end
-- 显示一次性通用提示，并让 Toast 层自行管理生命周期；不传时长时按字数给。
-- color 可选：这一条的字色（如好消息绿、坏消息红），不传用皮肤字色。
function Kit:ShowNotice(text,duration,color)
 local message=tostring(text or "")
 local seconds=math.max(.1,tonumber(duration) or Toast.Duration(message,Toast.Resolve(self.config_.toast).style))
 self.noticeText_=message;self.noticeColor_=color
 self.noticeDuration_=seconds
 self.noticeTime_=message~="" and seconds or 0
 self.noticeRevision_=self.noticeRevision_+1
 self:MarkStructureDirty();self:MarkDataDirty()
end
-- 判断当前是否存在仍在显示的通用提示。
function Kit:HasNotice() return self.noticeText_~="" and self.noticeTime_>0 end
-- 读取当前提示文本，供 Toast 控制器刷新文字。
function Kit:GetNotice() return self.noticeText_ end
-- 读取当前提示动画修订号，供重复提示重新播放动画。
function Kit:GetNoticeRevision() return self.noticeRevision_ end
-- 读取当前提示持续时间，供 Toast 控制器同步动画长度。
function Kit:GetNoticeDuration() return self.noticeDuration_ end
-- 读取当前提示的字色；nil 表示用皮肤字色。
function Kit:GetNoticeColor() return self.noticeColor_ end
-- 注册 JSON 面板，禁止旧 native 战场路径。
function Kit:RegisterPanel(key,definition)
 local def=copy(definition,{key=key,index=#self.order_+1})
 assert(def.shell=="main" or def.shell=="game" or def.shell=="overlay" or def.shell=="context","Missing UI shell: "..key)
 assert(not def.native and not def.mount and not def.build,"Only JSON UI panels are allowed: "..key)
 def.layer=def.layer or self.Layers.Page
 self.panels_[key]=def;self.order_[#self.order_+1]=def;self.registry_:Register(key,def)
 table.sort(self.order_,function(a,b) if a.layer==b.layer then return a.index<b.index end;return a.layer<b.layer end)
 self:MarkStructureDirty()
end
-- 设置阶段页面解析器。
function Kit:SetPhaseResolver(fn) self.phaseResolver_=fn;self:MarkStructureDirty() end
-- 打开独立页面；keepMounted 页面只切换可见状态，不销毁旧 JSON 树。
function Kit:OpenPage(key,props)
 local def=self.panels_[key]
 if not def or def.layer~=self.Layers.Page or not self.config_.allows(def,self.app_) then return false end
 if def.shell=="overlay" then self.overlayKey_=key else self.pageKey_=key end
 self.pageProps_[key]=props or self.pageProps_[key] or {}
 self.openRevision_[key]=(self.openRevision_[key] or 0)+1
 self:MarkStructureDirty()
 if self.arch and self.arch.events then self.arch.events:Fire("sumeru.ui.opened",key) end
 return true
end
-- 保留旧调用入口，内部统一走独立页面宿主。
function Kit:Open(key,props) return self:OpenPage(key,props) end
-- 关闭指定页面；缓存页面的 JSON 树保留，待下一次 OpenPage 重新显示。
function Kit:Close(key)
 key=key or self.overlayKey_ or self.pageKey_
 if not key then return false end
 if self.overlayKey_==key then self.overlayKey_=false elseif self.pageKey_==key then self.pageKey_=false else return false end
 self.pageProps_[key]=nil;self:MarkStructureDirty()
 if self.arch and self.arch.events then self.arch.events:Fire("sumeru.ui.closed",key) end
 return true
end
-- 显示或隐藏一个页面；页面内容仍由自己的 JSON 和控制器管理。
function Kit:SetPageVisible(key,visible)
 if visible then return self:OpenPage(key) end
 if self.pageKey_==key then return self:Close(key) end
 return false
end
-- 切换一个工具页面。
function Kit:Toggle(key) if self:CurrentPage()==key then return self:Close(key) end;return self:OpenPage(key) end
-- 返回最上方页面的业务键。
function Kit:CurrentPage() return self.overlayKey_ or self.pageKey_ or (self.phaseResolver_ and self.phaseResolver_(self.app_)) end
-- 读取对应页面参数。
function Kit:PageProps(key) return self.pageProps_[key or self:CurrentPage()] or {} end
-- 标记结构需要增量同步。
function Kit:MarkStructureDirty() self.structureDirty_=true end
-- 标记现有控件的数据需要刷新。
function Kit:MarkDataDirty() self.dataDirty_=true end
-- 刷新当前可见页面；隐藏缓存页面不会被旧数据重新绘制。
function Kit:RefreshVisiblePages() self:refresh_() end
-- 丢弃不属于当前阶段的显式页面，缓存页面会在宿主切换时统一卸载。
function Kit:SyncPhasePage(app)
 self.app_=app or self.app_
 if self.pageKey_ and (not self.panels_[self.pageKey_] or not self.config_.allows(self.panels_[self.pageKey_],self.app_)) then
  self.pageKey_=false
 end
 if self.overlayKey_ and (not self.panels_[self.overlayKey_] or not self.config_.allows(self.panels_[self.overlayKey_],self.app_)) then
  self.overlayKey_=false
 end
 self:MarkStructureDirty()
end
-- 判断面板可见性，隐藏缓存页不参与命中测试。
function Kit:panelVisible_(def,app)
 if not self.config_.allows(def,app) then return false end
 if def.layer==self.Layers.Page then return (def.shell=="overlay" and self.overlayKey_ or self.pageKey_)==def.key end
 if def.layer==self.Layers.PhasePage then return not self.pageKey_ and self.phaseResolver_ and self.phaseResolver_(app)==def.key end
 return not def.visible or def.visible(app,self)==true
end
-- 对外查询面板是否打开。
function Kit:IsOpen(key) local d=self.panels_[key];return d and self:panelVisible_(d,self.app_) or false end
-- 按层级挂载实际打开过的页面；缓存仅保存独立实例，不提前创建全部页面。
function Kit:desiredKeys_(app)
 local keys={};local cached={}
 for _,entry in ipairs(self.active_) do cached[entry.key]=entry end
 for _,def in ipairs(self.order_) do
  local entry=cached[def.key];local scope=def.scope and def.scope(app) or nil
  local keep=def.keepMounted and entry and entry.scope==scope and self.config_.allows(def,app)
  if keep or self:panelVisible_(def,app) then keys[#keys+1]=def.key end
 end
 return keys
end
-- 构造独立面板上下文；capsule 为宿主胶囊在画面内的位置（无胶囊时为 nil），供贴顶控件局部让位。
function Kit:context_(key,metrics,frame)
 return {app=self.app_,ui=self,panelKey=key,w=metrics.w,h=metrics.h,map=metrics.map,capsule=metrics.capsule,frame=frame,
  pageProps=self:PageProps(key),host=self.host_}
end
-- 隐藏时禁用命中，显示时恢复原始策略，避免透明宿主拦截下层点击。
function Kit:setEntryVisible_(entry,visible,reason)
 if visible then
  local revision=self.openRevision_[entry.key]
  local reopen=entry.revision~=revision
  entry.revision=revision
  entry:Show(entry.context.pageProps,reopen)
 else entry:Hide(reason or "hidden") end
end
-- 委托独立实例挂载和清理；框架不解释页面内容。
function Kit:mount_(key,descriptor,ctx)
 local entry=PanelInstance.new(key,descriptor,ctx)
 entry.revision=self.openRevision_[key];entry.scope=descriptor.scope and descriptor.scope(self.app_) or nil
 if descriptor.isShell or self:panelVisible_(descriptor,self.app_) then entry:Show() else entry:Mount() end
 return entry
end
-- 先解绑控制器和组件，再释放唯一拥有的 Widget 子树。
function Kit:destroyEntry_(entry,reason)
 entry:Destroy(reason)
end
-- 创建轻量基础容器：根容器铺底色，其下先放不裁剪、不避让安全区的全屏底层，再放裁剪到安全区内的业务画面框；整个应用只调用一次 SetRoot，直至关闭应用。
function Kit:ensureRoot_(metrics)
 if self.root_ then return end
 self.root_=UI.Panel{width="100%",height="100%",pointerEvents="box-none",backgroundColor=metrics.background}
 self.backdrop_=UI.Panel{position="absolute",left=0,top=0,width="100%",height="100%",pointerEvents="none"}
 self.frame_=UI.Panel{position="absolute",left=0,top=0,width=metrics.w,height=metrics.h,overflow="hidden",pointerEvents="box-none"}
 self.root_:AddChild(self.backdrop_);self.root_:AddChild(self.frame_);UI.SetRoot(self.root_,true)
end
-- 返回全屏底层：位于业务画面框之下，铺满整个屏幕（含刘海、摄像头和底部手势条等安全区外区域），不接收输入；
-- 业务可在其中挂背景控件，让背景延伸到安全区外。根容器建立前（首次 Flush 之前）返回 nil。
---@return Widget?
function Kit:Backdrop() return self.backdrop_ end
-- 只建立当前业务 Shell 和独立 OverlayPanel；路径按面板根路径约定推导，预加载组件取自配置。
function Kit:mountShell_(name,metrics)
 local key=name=="overlay" and "overlay" or name
 local template,controller=self.registry_:Paths(key)
 local descriptor={template=template,controller=controller,layer=name=="overlay" and 100 or 0,isShell=true,components=self.config_.shellComponents[name] or {}}
 local entry=self:mount_(key,descriptor,self:context_(key,metrics,self.frame_))
 self.shells_[name]=entry
end
-- 获取游戏 HUD / 建造 / 工具层或主页面 / Overlay 容器。
function Kit:parentFor_(def)
 local shell=def.shell=="context" and self.host_ or def.shell
 local entry=assert(self.shells_[shell],"Inactive UI shell: "..shell)
 return entry.controller:GetMountPoint(def),shell
end
-- 调度独立实例的显隐；作用域变化释放旧对局的页面实例。
function Kit:reconcile_(metrics,keys,resized)
 local host=self.config_.host(self.app_)
 local desired={};for _,key in ipairs(keys) do desired[key]=true end
 for i=#self.active_,1,-1 do
  local entry=self.active_[i];local scope=entry.def.scope and entry.def.scope(self.app_) or nil
  local reopened=entry.revision~=self.openRevision_[entry.key]
  if not desired[entry.key] or entry.scope~=scope or (host~=self.host_ and entry.shell~="overlay") or (reopened and (not entry.def.keepMounted or entry.failed)) then
   self:destroyEntry_(entry,"page-change");table.remove(self.active_,i)
  end
 end
 if self.host_~=host then
  if self.host_ and self.shells_[self.host_] then self:destroyEntry_(self.shells_[self.host_],"shell-change");self.shells_[self.host_]=nil end
  self.host_=host;self:mountShell_(host,metrics)
 end
 if not self.shells_.overlay then self:mountShell_("overlay",metrics) end
 local size={w=metrics.w,h=metrics.h,map=metrics.map,capsule=metrics.capsule,host=self.host_}
 for _,name in ipairs({self.host_,"overlay"}) do local entry=self.shells_[name];entry:Resize(size) end
 local existing={};for _,entry in ipairs(self.active_) do existing[entry.key]=true end
 for _,key in ipairs(keys) do
  if not existing[key] then
   local def=self.registry_:Resolve(key);local frame,shell=self:parentFor_(def)
   local entry=self:mount_(key,def,self:context_(key,metrics,frame));entry.shell=shell;self.active_[#self.active_+1]=entry
  end
 end
 for _,entry in ipairs(self.active_) do
  entry.context.pageProps=self:PageProps(entry.key)
  if resized then entry:Resize(size) end
  self:setEntryVisible_(entry,self:panelVisible_(entry.def,self.app_),"page-change")
 end
 self.activeKeys_=keys;self.structureDirty_=false;self.dataDirty_=true
end
-- 刷新存活控制器，不创建节点。
function Kit:refresh_()
 for _,entry in ipairs(self.active_) do entry:Refresh() end
end
-- 推进当前宿主和面板视觉；模拟系统由 App 独立推进。
function Kit:Update(dt)
 if self.noticeTime_>0 then
  self.noticeTime_=self.noticeTime_-math.max(0,dt or 0)
  if self.noticeTime_<=0 then
   self.noticeTime_=0;self.noticeText_="";self:MarkStructureDirty();self:MarkDataDirty()
  end
 end
 for _,name in ipairs({self.host_,"overlay"}) do local e=self.shells_[name];if e then e:Update(dt) end end
 for _,e in ipairs(self.active_) do if e.visible then e:Update(dt) end end
end
-- 同步屏幕尺寸、业务宿主和可见面板，Overlay 变化不重建战场。
function Kit:Flush(app)
 if not self.app_ then return end
 self.app_=app or self.app_;self:ensureRoot_(self.metrics_(self.app_))
 local m=self.metrics_(self.app_)
 local left=m.safe.left+(m.vw-m.safe.left-m.safe.right-m.w)/2
 local signature=table.concat({m.vw,m.vh,left,m.top,m.w,m.h},":")
 local resized=signature~=self.metricsKey_
 if resized then self.frame_:SetStyle({left=left,top=m.top,width=m.w,height=m.h});self.metricsKey_=signature end
 local keys=self:desiredKeys_(self.app_);local key=table.concat(keys,"|")
 for _,entry in ipairs(self.active_) do
  if entry.def.scope and entry.scope~=entry.def.scope(self.app_) then self.structureDirty_=true;break end
 end
 if resized or self.structureDirty_ or self.key_~=key or self.host_~=self.config_.host(self.app_) then
  self:reconcile_(m,keys,resized);self.key_=key
 end
 if self.dataDirty_ or self.app_.dirty then self:refresh_();self.dataDirty_=false;self.app_.dirty=false end
end
-- 关闭所有页面及宿主，不残留输入、动态节点和动画。
function Kit:Destroy()
 for i=#self.active_,1,-1 do self:destroyEntry_(self.active_[i],"shutdown") end
 for _,name in ipairs({self.host_,"overlay"}) do local e=self.shells_[name];if e then self:destroyEntry_(e,"shutdown") end end
 if self.root_ then UI.SetRoot(nil,true) end
 reset()
end
reset()
return Kit
