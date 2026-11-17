-- 运行环境：测试环境，还是玩家手里的正式版（手机 / 电脑）。整张表就是一个全局 Model：
-- 游戏在 main.lua 里 arch:RegisterModel("Env",require("sumeru.toolkit.envkit"))，之后 self:GetModel("Env") 和 require 拿到的是同一张表。
-- 测试环境只认两种来源：启动参数带 -sumeru_dev（框架的 play.ps1、shot.sh 会加），或代码里调 Enable（以后线上测试用）。
-- 不按平台猜（TapTap PC 版也是桌面平台），也不认 -tapcode_dir、-skip_login 这些引擎参数（宿主哪天改了就认错）。
-- 没有标识一律当正式版：认错的代价只是测试时看不了广告，不会白送玩家奖励。
local Env={}
Env.FLAG="-sumeru_dev"
Env.dev=false     -- 是不是测试环境
Env.source=nil    -- 怎么打开的："launch"（启动参数）、"override"（自检），或 Enable 传进来的来源
Env.features={}   -- 测试环境里单独关掉某个测试功能：Env.features.skipAds=false

local DESKTOP={Windows=true,Linux=true,Mac=true}
local MOBILE={Android=true,iOS=true,HarmonyOS=true}

local function launched()
 if type(GetArguments)~="function" then return false end
 for _,a in ipairs(GetArguments() or {}) do if a==Env.FLAG then return true end end
 return false
end
if launched() then Env.dev=true;Env.source="launch";print("[EnvKit] 测试环境（启动参数 "..Env.FLAG.."）") end

function Env.Platform() return GetPlatform() end
function Env.IsDesktop() return DESKTOP[GetPlatform()]==true end
function Env.IsMobile() return MOBILE[GetPlatform()]==true end

-- 测试环境：数据标成调试、兑换码用测试账号这类「是不是测试」的判断用它。
function Env.IsDev() return Env.dev end
-- 测试功能开关：测试环境里默认都开，Env.features[key]=false 单独关。
-- 框架用到的：skipAds（广告跳过，按看完发奖）。游戏自己的测试面板、秒升级等自己起名，比如 Env.Has("panel")。
function Env.Has(key) return Env.dev and Env.features[key]~=false end
-- 玩家在电脑上玩的正式版（TapTap PC）：没有广告。
function Env.IsPCRelease() return Env.IsDesktop() and not Env.dev end

-- 打开测试环境，source 写来源方便排查。以后线上测试（测试账号白名单、隐藏入口等）都走这里，别直接改 Env.dev。
function Env.Enable(source)
 Env.dev=true;Env.source=source or "code"
 print("[EnvKit] 测试环境已打开："..Env.source)
end
-- 自检用：true 当成测试环境，false 当成正式版，nil 恢复按启动参数判断。
function Env.Override(dev)
 if dev==nil then Env.dev=launched();Env.source=Env.dev and "launch" or nil
 else Env.dev=dev==true;Env.source="override" end
end

return Env
