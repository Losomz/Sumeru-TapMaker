-- 激励视频适配层：统一 Maker sdk 的异步回调、忙状态与失败兜底。
local Env=require("sumeru.toolkit.envkit")
---@class SumeruAdKit
---@field sdk table?
---@field busy boolean
---@field simulate boolean
---@field blocked boolean
local Kit={};Kit.__index=Kit
-- 设备看不了广告时 ShowRewardVideo 回调的 msg。
Kit.BLOCKED="device blocked"

function Kit.new(config)
 local self=setmetatable({},Kit);self:init(config);return self
end

-- simulate=true 时不调用宿主广告，直接按完整观看回调，只给本地开发走通奖励链路；不传时按 EnvKit.IsLocalDev()。
-- blocked=true 时这台设备看不了广告（TapTap PC 版没有广告）：请求直接失败，AdReward 提示去手机上看；不传时按 EnvKit.IsPCRelease()。
-- blocked 优先于 simulate：老项目传了 simulate=Platform.IsDesktopPlatform()，到了 PC 正式版也照样拦下，不会白给奖励。
function Kit:init(config)
 config=config or {};self.sdk=config.sdk;self.busy=false
 if config.simulate==nil then self.simulate=Env.IsLocalDev() else self.simulate=config.simulate==true end
 if config.blocked==nil then self.blocked=Env.IsPCRelease() else self.blocked=config.blocked==true end
end

function Kit:IsBusy() return self.busy end
function Kit:IsBlocked() return self.blocked end
-- 模拟模式总是可请求；正式环境需要宿主提供广告接口；看不了广告的设备不可请求。
function Kit:CanRequest() return not self.busy and not self.blocked and (self.simulate or self.sdk~=nil and type(self.sdk.ShowRewardVideoAd)=="function") end

-- 完整观看才把 success 交给业务；返回 false 且没有回调时也必须收尾一次。模拟模式立即按成功回调。
-- 失败时把宿主原始 msg 写进日志，正式包排查（如缺 @runtime.ad 广告位）只能靠这一行。
function Kit:ShowRewardVideo(done)
 if self.busy then return false,"广告正在播放" end
 self.busy=true
 local finished=false
 local function finish(result)
  if finished then return end
  finished=true;self.busy=false
  if type(result)~="table" then result={success=false,msg="广告暂不可用"} end
  if result.success~=true then print("[AdKit] 广告未完成 msg="..tostring(result.msg)) end
  if done then done(result) end
 end
 if self.blocked then finish({success=false,msg=Kit.BLOCKED});return false end
 if self.simulate then
  print("[AdKit] 本地开发模拟激励广告：按完整观看发放")
  finish({success=true,msg="local simulate"});return true
 end
 if not self.sdk or type(self.sdk.ShowRewardVideoAd)~="function" then finish({success=false,msg="当前平台不支持广告"});return false end
 local ok,accepted=pcall(function() return self.sdk:ShowRewardVideoAd(finish) end)
 if not ok then finish({success=false,msg="ShowRewardVideoAd 出错: "..tostring(accepted)});return false end
 if accepted==false then finish({success=false,msg="宿主未受理广告请求（检查 @runtime.ad 广告位配置）"});return false end
 return true
end

return Kit
