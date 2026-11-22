-- 九宫格接缝：官方 Widget:RenderSlicedImage 把九块各画成一个矩形，几何边缘抗锯齿让相邻两块的接合边各留一道半透明过渡，
-- 拉伸后沿切片线透出背后的画面，看着是一条细线（原因和实机对照见 README「九宫格内部出现细线」）。
-- 这里在 Widget 类上包一层：只在这次切片绘制里关掉几何抗锯齿，画完 nvgRestore 回到调用前的状态（不直接写回 1）。
-- 所有 backgroundFit="sliced" 的控件最后都走这个方法，子类继承而不另写，所以包一次就全盖住；整图、圆角、矢量照旧抗锯齿。
-- UIKit:Attach 默认装上（Configure{sliceSeams=false} 不装）；只装一次，重复调用无害。
local UI=require("urhox-libs/UI")

local SliceSeams={}
local installed_=false

function SliceSeams.Install()
 if installed_ then return end
 local Widget=UI.Widget
 local raw=Widget and Widget.RenderSlicedImage
 if not raw then print("[SliceSeams] 没找到 Widget.RenderSlicedImage，没装");return end
 installed_=true
 ---@diagnostic disable-next-line: duplicate-set-field
 function Widget:RenderSlicedImage(nvg,...)
  nvgSave(nvg);nvgShapeAntiAlias(nvg,0)
  raw(self,nvg,...)
  nvgRestore(nvg)
 end
end

function SliceSeams.Installed() return installed_ end

return SliceSeams
