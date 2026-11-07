-- 安全区：UIKit 画面框铺满整屏高度、不处理安全区；需要让开刘海、摄像头或手势条的面板自行读取并应用。
local UI=require("urhox-libs/UI")
local SafeArea={}
-- 返回屏幕四边需要让开的距离（UI 逻辑像素）：top 为刘海与摄像头，bottom 为手势条，left/right 为横屏挖孔。
---@return {top:number,bottom:number,left:number,right:number}
function SafeArea.Insets()
 local s=UI.GetSafeAreaInsets()
 return {top=s.top or 0,bottom=s.bottom or 0,left=s.left or 0,right=s.right or 0}
end
return SafeArea
