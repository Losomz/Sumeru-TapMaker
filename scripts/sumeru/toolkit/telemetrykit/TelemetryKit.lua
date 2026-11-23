-- 数据后台（GameAlgo）固定上报：事件名、字段、看板都由框架定死，游戏只填少数几个值。
-- 固定：启动（boot_*）、一关的开始和结束（level_start / level_end）、里程碑、广告曝光（ad_view，AdKit 自动报）。
-- 游戏能填：mode、level_name 这些值；里程碑节点名；level_end 最多 3 个事先声明的额外字段。别的字段一律丢掉，不开放自定义事件。
-- SDK 用项目里官方原样的 scripts/sdk/GameAlgo.lua（2.1.5-lua 起）；没加载上、出错、网络不通，这里都只是空操作，不影响游戏。
---@class SumeruTelemetryKit
local Kit={}

-- level_start 只认这几个字段；level_end 多一个 result，再加游戏声明的额外字段。
Kit.LEVEL_FIELDS={level_attempt_id="string",level_id="string",level_no="number",mode="string",level_name="string"}
Kit.RESULTS={win=true,lose=true,quit=true}
Kit.MILESTONES={new_user=true,global=true}
Kit.MAX_EXTRA=3
local EXTRA_TYPES={string=true,number=true,boolean=true}

---@type table? 初始化成功后的 SDK（测试时是假 SDK）
local ga=nil
---@type boolean
local debugMode=false
---@type table<string,string> 广告位 key → gap_ ID
local ads={}
---@type table<string,string> 额外字段名 → 类型
local extra={}
---@type table<string,boolean> 本次启动报过的里程碑
local sent={}
---@type table<string,boolean> 本次启动报过的 begin / ready
local booted={}
local seq=0

local function warn(text) print("[TelemetryKit] "..text) end

-- 调 SDK：出错只打印，不往外抛。
local function call(name,...)
 if not ga then return false end
 local fn=ga[name]
 if type(fn)~="function" then return false end
 local ok,res,err=pcall(fn,...)
 if not ok then warn(name.." 出错："..tostring(res));return false end
 if res==false and err and debugMode then warn(name.." 没入队："..tostring(err)) end
 return res,err
end

-- SDK 日志：调试时全打；正式包只留失败类，真机好查。
local function logger(line)
 if debugMode or line:find("fail") or line:find("error") or line:find("reject") or line:find("timeout") then print(line) end
end

-- 额外字段：最多 3 个，名字只能小写字母数字下划线、不能和固定字段重名，类型 string / number / boolean。不合规的整份不认，打一行。
local function readExtra(list)
 local out,n={},0
 for name,t in pairs(list or {}) do
  n=n+1
  if type(name)~="string" or not name:match("^[a-z][a-z0-9_]*$") or Kit.LEVEL_FIELDS[name] or name=="result" or not EXTRA_TYPES[t] then
   warn("extraFields 里的 "..tostring(name).."="..tostring(t).." 不合规，额外字段一个都不报");return {}
  end
  out[name]=t
 end
 if n>Kit.MAX_EXTRA then warn("extraFields 最多 "..Kit.MAX_EXTRA.." 个，现在 "..n.." 个，额外字段一个都不报");return {} end
 return out
end

local function configure(cfg)
 cfg=cfg or {}
 debugMode=cfg.isDebug==true
 ads={}
 for key,id in pairs(cfg.ads or {}) do ads[key]=id end
 extra=readExtra(cfg.extraFields)
 sent={};booted={}
end

-- 启动时最先调一次（官方要求在存档、界面、广告之前）。isDebug：测试环境为真，这些事件不进正式报表。
---@param cfg {baseUrl:string,gameKey:string,appVersion:string,ads:table<string,string>?,extraFields:table<string,string>?,isDebug:boolean?}
---@return boolean
function Kit.Init(cfg)
 if ga then return true end
 configure(cfg)
 local ok,mod=pcall(require,"sdk.GameAlgo")
 if not ok or type(mod)~="table" then warn("SDK 没加载上："..tostring(mod));return false end
 local inited,err=pcall(mod.Init,{baseUrl=cfg.baseUrl,gameKey=cfg.gameKey,appVersion=cfg.appVersion,
  device={runtime="taptap_mini_game"},isDebug=debugMode,logger=logger})
 if not inited then warn("初始化失败："..tostring(err));return false end
 ga=mod
 print(string.format("[TelemetryKit] 就绪 debug=%s app %s",tostring(debugMode),tostring(cfg.appVersion)))
 return true
end

---@return boolean
function Kit.Ready() return ga~=nil end

-- 测试用：换成假 SDK（记下每条上报），cfg 同 Init；传 nil 换回没初始化。
---@param fake table?
---@param cfg table?
function Kit.UseSdk(fake,cfg)
 ga=fake
 configure(cfg)
end

-- 一次尝试的 ID：同一次的 level_start / level_end 共用，每次重新开都换新的。游戏自己有稳定 ID（比如存在存档里）就用自己的。
---@param prefix string
---@return string
function Kit.AttemptId(prefix)
 seq=seq+1
 return string.format("%s_%d_%06d_%d",prefix,os.time(),math.random(0,999999),seq)
end

-- 只留认得的字段；必填的不对就整条不报。返回 nil 表示不报。
local function clean(event,p,allowed)
 if type(p)~="table" then warn(event.." 要传一张表");return nil end
 ---@type table<string,any>
 local out={}
 for k,v in pairs(p) do
  local t=allowed[k]
  if t and type(v)==t then out[k]=v
  elseif debugMode then warn(event.." 丢掉字段 "..tostring(k).."（"..(t and "该是 "..t or "没声明").."）") end
 end
 for _,k in ipairs({"level_attempt_id","level_id","mode"}) do
  if type(out[k])~="string" or out[k]=="" then warn(event.." 缺 "..k.."，这条不报");return nil end
 end
 if type(out.level_no)=="number" then out.level_no=math.floor(out.level_no) end
 return out
end

-- 一关开始：level_attempt_id、level_id、mode 必填；level_no（可比较的进度）、level_name（中文名）选填。
---@param p {level_attempt_id:string,level_id:string,mode:string,level_no:integer?,level_name:string?}
---@return boolean
function Kit.LevelStart(p)
 if not ga then return false end
 local e=clean("level_start",p,Kit.LEVEL_FIELDS)
 if not e then return false end
 return call("TrackLevelStart",e)==true
end

-- 一关结束：字段和开始那条一样，再加 result（win / lose / quit）和 Init 时声明过的额外字段。
---@param p table
---@return boolean
function Kit.LevelEnd(p)
 if not ga then return false end
 local allowed={result="string"}
 for k,t in pairs(Kit.LEVEL_FIELDS) do allowed[k]=t end
 for k,t in pairs(extra) do allowed[k]=t end
 local e=clean("level_end",p,allowed)
 if not e then return false end
 if not Kit.RESULTS[e.result] then warn("level_end 的 result 只能是 win / lose / quit，收到 "..tostring(p.result).."，这条不报");return false end
 return call("TrackLevelEnd",e)==true
end

-- 里程碑：new_user 是新手前期流程，global 是中长期进度；节点名要和看板配置（dev/gamealgo/game.json）里的一致。
-- 本次启动报过的不再报；跨启动去重由 SDK 按人做。
---@param kind string new_user / global
---@param point string
---@return boolean
function Kit.Milestone(kind,point)
 if not ga then return false end
 if not Kit.MILESTONES[kind] then warn("里程碑只有 new_user / global，收到 "..tostring(kind));return false end
 point=tostring(point or "")
 if point=="" then return false end
 local k=kind.."|"..point
 if sent[k] then return false end
 sent[k]=true
 return call("TrackMilestone",kind,point)==true
end

-- 启动漏斗：直接接 BootKit 的 onEvent；不用 BootKit 的游戏自己在开始启动、第一页显示出来时各调一次。
-- begin {} 和 ready {sec, retries, manual} 每次启动各报一次；fail {stage, failed, retries, sec}、retry {manual} 每次都报；auto_retry 不报（ready / fail 里有总数）。
---@param name string begin / ready / fail / retry
---@param data table?
function Kit.Boot(name,data)
 if not ga then return end
 data=data or {}
 local function num(v) return type(v)=="number" and v or 0 end
 if name=="begin" or name=="ready" then
  if booted[name] then return end
  booted[name]=true
 end
 if name=="begin" then call("TrackEvent","boot_begin",{})
 elseif name=="ready" then call("TrackEvent","boot_ready",{sec=math.floor(num(data.sec)*10+0.5)/10,retries=num(data.retries),manual=num(data.manual)})
 elseif name=="fail" then call("TrackEvent","boot_fail",{stage=tostring(data.stage or ""),failed=num(data.failed),retries=num(data.retries),sec=math.floor(num(data.sec)*10+0.5)/10})
 elseif name=="retry" then call("TrackEvent","boot_retry",{manual=num(data.manual)}) end
end

---------------------------------------------------------------- 广告（AdKit 调，游戏不用直接碰）
-- 这个广告位 key 登记的 gap_ ID；没登记返回 nil。
---@param key string?
---@return string?
function Kit.AdId(key) return key and ads[key] or nil end

-- 交给 SDK 代放：它调宿主 sdk:ShowRewardVideoAd，收场时自己报 ad_view，再把结果交给 cb。
-- 没就绪、key 没登记时返回 nil，调用方自己放（再用 AdClosed 补报）；返回 true / false 是宿主受理没有。
---@param key string?
---@param cb fun(result:table?)
---@return boolean?
function Kit.ShowRewardVideoAd(key,cb)
 local id=Kit.AdId(key)
 if not ga or not id or type(ga.ShowRewardVideoAd)~="function" then return nil end
 local accepted,err=call("ShowRewardVideoAd",id,cb,{})
 if accepted~=true and err then warn("广告 "..tostring(key).." 没放出来："..tostring(err)) end
 return accepted==true
end

-- 调用方自己放的广告，宿主回调了就补报一次 ad_view（提前关闭、失败也报，跟 SDK 代放一样），trackId 原样带上。
---@param key string?
---@param result table?
function Kit.AdClosed(key,result)
 if not ga or not key then return end
 local id=ads[key]
 if not id then warn("没登记的广告位："..tostring(key));return end
 local trackId=nil
 if type(ga.ExtractAdTrackId)=="function" then
  local ok,v=pcall(ga.ExtractAdTrackId,result)
  if ok then trackId=v end
 end
 call("TrackAdPlacement",id,0,"taptap",{trackId=trackId})
 if not trackId then warn("广告回调没有 trackId："..tostring(key)) end
end

return Kit
