-- 运行环境：本地开发，还是玩家手里的正式版（手机 / 电脑）。
-- TapTap PC 版也是桌面平台，所以「桌面」不等于「本地开发」：按桌面开模拟广告、假数据，PC 玩家会白拿广告奖励、数据被标成调试。
-- 本地开发 = 桌面平台 + 启动参数带 -tapcode_dir=（直接跑本地源码目录）。Maker 本地预览、dev/sumeru/play.ps1、shot.sh 都带；
-- 正式版从下载的游戏包启动，不会带。不认 -skip_login：PC 客户端登录过后也可能带它，认错了就是白送奖励；
-- 反过来认错（比如本地跑远端包 -game_url）只是看不了广告，开发时一眼就能发现。
local Env={}
local DESKTOP={Windows=true,Linux=true,Mac=true}
local MOBILE={Android=true,iOS=true,HarmonyOS=true}
local localDev=nil

function Env.Platform() return GetPlatform() end
function Env.IsDesktop() return DESKTOP[GetPlatform()]==true end
function Env.IsMobile() return MOBILE[GetPlatform()]==true end

-- 本地开发：模拟广告、数据标成调试、兑换码用测试账号都只认这个。
function Env.IsLocalDev()
 if localDev==nil then
  localDev=false
  if Env.IsDesktop() and type(GetArguments)=="function" then
   for _,a in ipairs(GetArguments() or {}) do if a:sub(1,13)=="-tapcode_dir=" then localDev=true;break end end
  end
 end
 return localDev
end

-- 玩家在电脑上玩的正式版（TapTap PC）：没有广告。
function Env.IsPCRelease() return Env.IsDesktop() and not Env.IsLocalDev() end

-- 测试用：true 当成本地开发，false 当成正式版（在桌面上就是 PC 正式版），nil 恢复按启动参数判断。
function Env.Override(dev) localDev=dev end

return Env
