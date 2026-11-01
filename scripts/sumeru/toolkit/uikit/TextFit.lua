-- 文字自适应底板：按实际文字测量底板尺寸，短文字收窄成单行，超过最大宽度按最大宽度换行并增高；字号不变，避免文字被裁掉。
-- 测量与 Label 渲染共用 UI.MeasureTextFit，字体回退、字距与行高一致；不引用任何业务模块。
local UI=require("urhox-libs/UI")
local Theme=UI.Theme
---@class SumeruTextFit
local TextFit={}
-- 测量余量（像素）：防止取整误差让刚好放下的文字意外折行或被裁掉。
local SLACK=2
TextFit.SLACK=SLACK
-- 测量文字底板：返回底板宽高、文字区宽高与是否换行；cache 复用上次测量结果，同一段文字每帧调用只命中缓存。
---@param text string
---@param opt SumeruTextFitOptions
---@param cache SumeruTextFitCache?
---@return {width:number,height:number,textWidth:number,textHeight:number,wrapped:boolean}
function TextFit.Measure(text,opt,cache)
 cache=cache or {}
 local padX,padY=opt.padX or 0,opt.padY or 0
 local inner=math.max(1,opt.maxWidth-padX*2)
 local fontSize,fontFace=Theme.FontSize(opt.fontSize),Theme.FontFace(opt.fontFamily,opt.fontWeight)
 local spacing,lineHeight=opt.letterSpacing or 0,opt.lineHeight or 1
 -- 先按单行测（宽高给足够大的有限值，确保真正测量）；放不下再按文字区宽度换行测高度。
 local line=UI.MeasureTextFit(text or "",{fontSize=fontSize,fontFace=fontFace,letterSpacing=spacing,lineHeight=lineHeight,
  width=1000000,height=1000000,cache=cache.line})
 cache.line=line
 local w=(line.width or 0)+SLACK
 local h=(line.height or 0)+SLACK
 local wrapped=w>inner
 if wrapped then
  local wrap=UI.MeasureTextFit(text or "",{fontSize=fontSize,fontFace=fontFace,letterSpacing=spacing,lineHeight=lineHeight,
   width=inner,height=1000000,multiline=true,cache=cache.wrap})
  cache.wrap=wrap
  w=inner;h=(wrap.height or 0)+SLACK
 end
 local width=math.max(opt.minWidth or 0,math.min(opt.maxWidth,w+padX*2))
 local height=math.max(opt.minHeight or 0,h+padY*2)
 return {width=width,height=height,textWidth=width-padX*2,textHeight=height-padY*2,wrapped=wrapped}
end
-- 写入文字并把底板和文字 Label 设为测出的尺寸：文字占满内边距内的区域（Label 需 whiteSpace="normal"），返回底板宽高供调用方定位。
---@param box table 底板控件
---@param label table 文字 Label，绝对定位在底板内
---@param text string
---@param opt SumeruTextFitOptions
---@param cache SumeruTextFitCache?
---@return number width,number height
function TextFit.Apply(box,label,text,opt,cache)
 local m=TextFit.Measure(text,opt,cache)
 label:SetText(text)
 box:SetStyle({width=m.width,height=m.height})
 label:SetStyle({left=opt.padX or 0,top=opt.padY or 0,width=m.textWidth,height=m.textHeight})
 return m.width,m.height
end
return TextFit

-- 测量参数与缓存类型。
---@class SumeruTextFitOptions
---@field fontSize number 字号（pt，与 Label.fontSize 同单位）
---@field fontFamily string? 字体族，与 Label.fontFamily 一致
---@field fontWeight string? 字重，与 Label.fontWeight 一致
---@field lineHeight number? 行高倍数，默认 1
---@field letterSpacing number? 字距（像素），默认 0
---@field maxWidth number 底板最大宽度
---@field minWidth number? 底板最小宽度，默认 0
---@field minHeight number? 底板最小高度，默认 0
---@field padX number? 左右内边距，默认 0
---@field padY number? 上下内边距，默认 0
---@class SumeruTextFitCache
---@field line table? 单行测量缓存
---@field wrap table? 换行测量缓存
