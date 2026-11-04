-- 通用提示（Toast）：框架内置的一条提示，默认开启。尺寸、字号、自适应、位置、动画和时长由框架定，
-- 项目只在 UIKit:Configure({toast=...}) 里换底图、文字，必要时按项改默认样式；量字折行、替换旧提示等逻辑不开放。
local TextFit=require("sumeru.toolkit.uikit.TextFit")
---@class SumeruToast
---@field ctx table
---@field bar table 底板
---@field text table 文字 Label
---@field skin SumeruToastSkin
---@field fit SumeruTextFitCache
---@field lineFit SumeruTextFitCache 一行高度的测量缓存
---@field revision integer
---@field warned string?
local Toast={};Toast.__index=Toast
Toast.KEY="sumeru-toast"
Toast.TEMPLATE="sumeru/toolkit/uikit/toast/toast.ui.json"
Toast.CONTROLLER="sumeru.toolkit.uikit.toast.Toast"
-- 默认样式：项目 style 里写了哪项就覆盖哪项。
---@type SumeruToastStyle
Toast.DEFAULT={
 fontSize=16,lineHeight=1,padX=16,padY=10,
 minWidth=160,maxWidth=400,margin=24,minHeight=48,warnLines=3,
 anchorY=.42,rise=12,fadeIn=.15,fadeOut=.3,
 minDuration=2,maxDuration=5,
}
-- 没给底图、文字时用的默认外观。
Toast.DEFAULT_BACKGROUND={color={24,20,24,235},borderColor={120,100,80,255},borderWidth=2,borderRadius=6}
Toast.DEFAULT_TEXT={color={244,236,220,255}}

-- 合并项目配置与默认值：background、text 整组替换，style 逐项覆盖；toast=false/nil/true 都按默认处理。
---@param cfg SumeruToastConfig|boolean|nil
---@return SumeruToastSkin
function Toast.Resolve(cfg)
 if type(cfg)~="table" then cfg={} end
 local style={}
 for k,v in pairs(Toast.DEFAULT) do style[k]=v end
 for k,v in pairs(cfg.style or {}) do style[k]=v end
 return {background=cfg.background or Toast.DEFAULT_BACKGROUND,text=cfg.text or Toast.DEFAULT_TEXT,style=style}
end
-- 按字数给提示时长：1.2 + 0.12×字数，夹在 minDuration 与 maxDuration 之间。
---@param text string
---@param style SumeruToastStyle?
---@return number
function Toast.Duration(text,style)
 style=style or Toast.DEFAULT
 text=tostring(text or "")
 local n=utf8.len(text) or #text
 return math.max(style.minDuration,math.min(style.maxDuration,1.2+.12*n))
end

-- 创建 Toast 控制器。
function Toast.new() return setmetatable({},Toast) end
-- 套用皮肤：有底图按九宫格拉伸，没有就用默认底色描边；文字套字体、字色、字号和行高。
function Toast:Init(ctx)
 self.ctx=ctx;self.fit={};self.lineFit={};self.revision=-1
 self.bar=ctx.json:Find("sumeru-toast-bar");self.text=ctx.json:Find("sumeru-toast-text")
 local skin=Toast.Resolve(ctx.ui.config_.toast);self.skin=skin
 local bg=skin.background
 if bg.image then
  self.bar:SetStyle({backgroundImage=bg.image,backgroundFit="sliced",backgroundSlice=bg.slice,backgroundColor={0,0,0,0},borderWidth=0,borderRadius=0})
 else
  self.bar:SetStyle({backgroundColor=bg.color,borderColor=bg.borderColor,borderWidth=bg.borderWidth or 0,borderRadius=bg.borderRadius or 0})
 end
 local text=skin.text
 self.text:SetStyle({fontSize=skin.style.fontSize,lineHeight=skin.style.lineHeight,fontColor=text.color or Toast.DEFAULT_TEXT.color,fontFamily=text.font})
 self:Resize(ctx)
end
-- 测量选项：与文字 Label 的字体参数一致，最大宽度按屏宽夹住。
function Toast:fitOptions_(w)
 local s=self.skin.style
 return {fontSize=s.fontSize,fontFamily=self.skin.text.font,lineHeight=s.lineHeight,
  maxWidth=math.min(w-s.margin*2,s.maxWidth),minWidth=s.minWidth,minHeight=s.minHeight,padX=s.padX,padY=s.padY}
end
-- 按当前文字自适应底板，并让底板中心落在 anchorY 处；超过 warnLines 行时提醒文案太长。
function Toast:Layout(ctx)
 self.ctx=ctx;ctx.root:SetStyle({width=ctx.w,height=ctx.h})
 local message=ctx.ui:GetNotice();local opt=self:fitOptions_(ctx.w);local s=self.skin.style
 local width,height=TextFit.Apply(self.bar,self.text,message,opt,self.fit)
 self.bar:SetStyle({left=(ctx.w-width)/2,top=ctx.h*s.anchorY-height/2})
 -- 行数按实测的一行高度算（字体的行框通常比字号高），两边都先去掉测量余量。
 local one=TextFit.Measure("字",{fontSize=opt.fontSize,fontFamily=opt.fontFamily,lineHeight=opt.lineHeight,maxWidth=1000000},self.lineFit)
 local lines=math.floor((height-s.padY*2-TextFit.SLACK)/math.max(1,one.textHeight-TextFit.SLACK)+.5)
 if lines>s.warnLines and self.warned~=message then
  self.warned=message;print("[Toast] 提示有 "..lines.." 行，超过 "..s.warnLines.." 行，文案太长："..message)
 end
end
-- 屏幕尺寸变化时重排。
function Toast:Resize(ctx) self:Layout(ctx) end
-- 提示修订号变化时重排并重播动画：淡入上移、停留、淡出再上移。
function Toast:Refresh()
 local ui=self.ctx.ui;local revision=ui:GetNoticeRevision()
 if self.revision==revision then return end
 self.revision=revision
 -- 这一条指定了字色就用它，没指定回到皮肤字色。
 self.text:SetStyle({fontColor=ui.GetNoticeColor and ui:GetNoticeColor() or self.skin.text.color or Toast.DEFAULT_TEXT.color})
 self:Layout(self.ctx)
 local s=self.skin.style;local duration=ui:GetNoticeDuration()
 local a=math.min(.45,s.fadeIn/duration);local b=math.max(a,1-s.fadeOut/duration)
 self.bar:StopAnimation()
 self.bar:SetStyle({opacity=0,translateY=s.rise})
 self.bar:Animate({
  keyframes={[0]={opacity=0,translateY=s.rise},[a]={opacity=1,translateY=0},[b]={opacity=1,translateY=0},[1]={opacity=0,translateY=-s.rise*2}},
  duration=duration,easing="easeOut",fillMode="both",
 })
end
-- 首次显示时播放。
function Toast:Show() self:Refresh() end
-- 隐藏时停止动画，避免残留回调。
function Toast:Hide() if self.bar then self.bar:StopAnimation() end end
-- 释放引用，控件由 UIKit 统一销毁。
function Toast:Destroy() self.ctx=nil;self.bar=nil;self.text=nil end
return Toast

-- 配置类型。
---@class SumeruToastConfig
---@field background SumeruToastBackground? 底图或底色，整组替换默认
---@field text SumeruToastText? 字体与字色，整组替换默认
---@field style SumeruToastStyle? 按项覆盖默认样式
---@class SumeruToastBackground
---@field image string? 底图路径，按九宫格拉伸
---@field slice number[]? 底图切片：上、右、下、左，按图片像素；有 image 时必填
---@field color number[]? 无底图时的底色
---@field borderColor number[]? 无底图时的描边色
---@field borderWidth number? 无底图时的描边宽度
---@field borderRadius number? 无底图时的圆角
---@class SumeruToastText
---@field font string? 字体族，默认主题字体
---@field color number[]? 字色
---@class SumeruToastStyle
---@field fontSize number 字号（pt）
---@field lineHeight number 行高倍数
---@field padX number 左右内边距
---@field padY number 上下内边距
---@field minWidth number 底板最窄
---@field maxWidth number 底板最宽（还会被屏宽减两侧 margin 夹住）
---@field margin number 底板离屏幕左右边的最小距离
---@field minHeight number 底板最矮（一行）
---@field warnLines number 超过这么多行打日志提醒
---@field anchorY number 底板中心在屏高的比例
---@field rise number 淡入上移距离；淡出再上移两倍
---@field fadeIn number 淡入秒数
---@field fadeOut number 淡出秒数
---@field minDuration number 不传时长时的最短秒数
---@field maxDuration number 不传时长时的最长秒数
---@class SumeruToastSkin
---@field background SumeruToastBackground
---@field text SumeruToastText
---@field style SumeruToastStyle
