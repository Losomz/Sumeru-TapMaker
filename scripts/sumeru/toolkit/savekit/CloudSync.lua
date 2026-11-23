-- 云存档：本地存档照旧是主存档，云端（clientCloud 的 values）多存一份，换手机、重装、多设备时接上进度。
-- 云端一条记录 {rev, device, at, text}：text 是 SaveKit 编好的存档文本，rev 每上传一次加一，device 是上传的设备号。
-- 存档根节点放一份同步状态 sync={device, rev, dirty}：本机设备号、本机基于云端第几版、上传后本机又存过档没有。
-- 判定只看这三样，不比时间（设备时钟不可靠）；两边各有新进度时交给玩家选，不自动覆盖。
-- 所有回调只认一次：超时、迟到、重复的回调丢掉。SDK 调用包在 pcall 里，出错打 [CloudSync] 日志。
local RedeemKit=require("sumeru.toolkit.redeemkit.RedeemKit")

---@class SumeruCloudSync
---@field kit SumeruSaveKit
---@field key string
---@field data fun(): any 取当前整份存档数据（根节点要有 sync）
---@field save fun()
---@field gap number
---@field timeout number
---@field onConflict fun(cloudData: table, info: table)|nil
---@field onChange fun()|nil
---@field cloud table|nil
---@field userId (fun(): any)|nil
---@field now fun(): number
---@field t number
---@field timer number
---@field touches integer
---@field inflight table
---@field state string
---@field at number|nil
---@field busy boolean
---@field conflict table|nil
local CloudSync={};CloudSync.__index=CloudSync

local function log(text) print("[CloudSync] "..text) end

-- 存档里的同步状态，游戏放进 schema 根节点：sync=CloudSync.Schema()。
function CloudSync.Schema() return {device="",rev=0,dirty=false} end

-- 随机设备号（12 位小写字母和数字）：每台设备第一次启动时生成，存在本地存档里。
-- 不只靠 math.random：游戏常用 os.time() 播种，同一秒启动的两台设备会撞号，所以再掺上时钟和内存地址。
local function newDevice()
 local chars="0123456789abcdefghijklmnopqrstuvwxyz";local out={}
 local seed=os.time()+math.floor(os.clock()*1000003)+(tonumber(tostring({}):match("0x(%x+)") or "0",16) or 0)
 for i=1,12 do
  seed=(seed*1103515245+12345+math.random(0,65535))%2147483648
  local k=seed%#chars+1;out[i]=chars:sub(k,k)
 end
 return table.concat(out)
end

-- opts：
--  kit：SaveKit 实例（云端文本用它的 Encode/Decode，结构和版本规则与本地一致）。
--  key：云变量名，上线后不能改。
--  data()：取当前整份存档数据（根节点要有 sync）。save()：写一次本地存档，不要经过会标脏的路径。
--  gap（定时上传间隔，默认 180 秒）、timeout（请求超时，默认 8 秒）。
--  onConflict(cloudData, info)：上传前发现别的设备写过更新的存档；onChange()：状态变了（刷新界面）。
--  测试注入：cloud（同 clientCloud）、userId（函数）、now（函数，默认 os.time）。
function CloudSync.new(opts)
 local self=setmetatable({},CloudSync)
 self.kit=assert(opts.kit,"[CloudSync] 缺少 kit")
 self.key=assert(opts.key,"[CloudSync] 缺少 key")
 self.data=assert(opts.data,"[CloudSync] 缺少 data")
 self.save=opts.save or function() end
 self.gap=opts.gap or 180
 self.timeout=opts.timeout or 8
 self.onConflict=opts.onConflict
 self.onChange=opts.onChange
 self.cloud=opts.cloud
 self.userId=opts.userId
 self.now=opts.now or os.time
 self.t=0;self.timer=0;self.touches=0
 self.inflight={}
 self.state="idle";self.at=nil;self.busy=false;self.conflict=nil
 return self
end

function CloudSync:cloud_()
 if self.cloud then return self.cloud end
 local ok,c=pcall(function() return clientCloud end)
 return ok and c or nil
end
function CloudSync:uid_()
 if self.userId then local ok,v=pcall(self.userId);return ok and v~=nil and tostring(v) or nil end
 return RedeemKit.UserId()
end
function CloudSync:changed_()
 if not self.onChange then return end
 local ok,err=pcall(self.onChange)
 if not ok then log("onChange 出错："..tostring(err)) end
end
function CloudSync:set_(state) if self.state~=state then self.state=state;self:changed_() end end

-- 同步状态：没有设备号就生成一个。
function CloudSync:sync_(data)
 data.sync=data.sync or CloudSync.Schema()
 local s=data.sync
 if type(s.device)~="string" or s.device=="" then s.device=newDevice() end
 return s
end

-- 发一个请求：done(ok, ...) 只回调一次，超时按失败。
function CloudSync:call_(name,fn,done)
 local req={deadline=self.t+self.timeout}
 local finished=false
 local function finish(ok,...)
  if finished then return end
  finished=true;self.inflight[req]=nil
  local fine,err=pcall(done,ok,...)
  if not fine then log(name.." 回调出错："..tostring(err)) end
 end
 req.finish=finish
 self.inflight[req]=true
 local events={
  ok=function(...) finish(true,...) end,
  error=function(code,reason) log(name.." 失败 code="..tostring(code).." "..tostring(reason or ""));finish(false,code) end,
  timeout=function() log(name.." 超时");finish(false,"timeout") end,
 }
 local ok,err=pcall(fn,events)
 if not ok then log(name.." 调用出错："..tostring(err));finish(false,"exception") end
end

-- 读云端记录：done(ok, record)；record 为 {rev,device,at,text} 或 nil（没有、格式不对）。
function CloudSync:get_(cloud,done)
 self:call_("读取云存档",function(ev) cloud:Get(self.key,ev) end,function(ok,values)
  if not ok then return done(false) end
  local rec=type(values)=="table" and values[self.key] or nil
  if type(rec)=="string" then
   local fine,decoded=pcall(self.kit.codec.decode,rec)
   rec=fine and decoded or nil
  end
  if type(rec)~="table" or type(rec.text)~="string" or type(rec.device)~="string" then return done(true,nil) end
  done(true,{rev=math.floor(tonumber(rec.rev) or 0),device=rec.device,at=math.floor(tonumber(rec.at) or 0),text=rec.text})
 end)
end

-- 云端记录解成存档：旧版本的照 SaveKit 规则修补、补全后用；解不开、或是比代码新的版本（别的设备装了新版）时返回 nil，
-- 本机用了会丢掉新版本的字段。
function CloudSync:decode_(rec)
 if not rec then return nil end
 local data,isNew,info=self.kit:Decode(rec.text)
 if isNew then log("云端存档解不开，不用它");return nil end
 if info and info.newer then log("云端存档是更新的版本（"..tostring(info.from).."），本机代码是 "..self.kit.version.."，不用它");return nil end
 return data,{rev=rec.rev,device=rec.device,at=rec.at}
end

-- 云端记录的存档版本比本机代码新：本机不能覆盖它（会丢掉新版本的字段）。
function CloudSync:newer_(rec)
 local v=rec and self.kit:VersionOf(rec.text)
 return v~=nil and v>self.kit.version
end

---------------------------------------------------------------- 启动
-- 启动时判定用哪份存档，done({use="local"|"cloud"|"conflict", data=云端数据, info={rev,device,at}})。
-- 没登录、读不到、超时、云端没有、解不开或是更新的版本都用本机的；本机是新档就用云端的；
-- 云端是别的设备传的更新版本时，本机上传后没动过就用云端的，动过就是冲突（先用本机的进游戏，再让玩家选）。
function CloudSync:Check(data,isNew,done)
 local s=self:sync_(data)
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then self:set_("off");return done({use="local"}) end
 self:set_("busy")
 self:get_(cloud,function(ok,rec)
  if not ok then self:set_("error");return done({use="local"}) end
  local cdata,info=self:decode_(rec)
  local r
  if not cdata then r={use="local"}
  elseif isNew then r={use="cloud",data=cdata,info=info}
  elseif info.device==s.device or info.rev<=s.rev then r={use="local"}
  elseif not s.dirty then r={use="cloud",data=cdata,info=info}
  else r={use="conflict",data=cdata,info=info} end
  if r.use=="conflict" then self.conflict=r;self:set_("conflict")
  else
   self:set_(cdata and "ok" or "idle")
   -- 上次同步的时间：用了云端的就是现在；云端是本机传的就是那次上传的时间
   if r.use=="cloud" then self.at=self.now() elseif info and info.device==s.device then self.at=info.at end
  end
  log("启动判定："..r.use..(info and (" 云端 rev="..info.rev) or "").." 本机 rev="..s.rev..(s.dirty and " 有新进度" or ""))
  done(r)
 end)
end

-- 接过云端的存档（启动判定为 cloud，或玩家在冲突里选了云端）：版本号取云端的，设备号保留本机的，清掉脏标记。
function CloudSync:Adopt(cloudData,info)
 local mine=self:sync_(self.data()).device
 local s=self:sync_(cloudData)
 s.device=mine;s.rev=info.rev;s.dirty=false
 self.conflict=nil;self.at=self.now();self.timer=0
 self:set_("ok")
 return cloudData
end

-- 本机又存档了：标脏。游戏每次存档前调（上传成功后的那次本地写除外）。
function CloudSync:Touch()
 local d=self.data();if type(d)~="table" then return end
 self:sync_(d).dirty=true
 self.touches=self.touches+1
end

---------------------------------------------------------------- 上传
-- 上传本机存档：先读云端，别的设备写过更新的版本就不覆盖，转成冲突（回调 onConflict）；force 时直接覆盖（玩家选了本机的）。
-- 云端存档是比本机代码新的版本时，force 也不覆盖（本机是旧版本，传上去会丢字段），等本机更新。
-- 成功后版本号加一、清掉脏标记并写一次本地。正在上传、有冲突没处理（非 force）、没登录时不做。
function CloudSync:Push(force)
 if self.busy then return false end
 if self.conflict and not force then return false end
 local cloud,uid=self:cloud_(),self:uid_()
 if not cloud or not uid then self:set_("off");return false end
 local data=self.data();local s=self:sync_(data)
 self.busy=true;self.timer=0;self:set_("busy")
 local function fail() self.busy=false;self:set_(self.conflict and "conflict" or "error") end
 self:get_(cloud,function(ok,rec)
  if not ok then return fail() end
  if self.data()~=data then self.busy=false;return self:set_("idle") end
  if self:newer_(rec) then
   self.busy=false;self:set_("idle")
   log("云端存档是更新的版本，本机不覆盖它（先更新游戏）")
   return
  end
  if rec and not force and rec.device~=s.device and rec.rev>s.rev then
   local cdata,info=self:decode_(rec)
   if cdata then
    self.busy=false;self.conflict={use="conflict",data=cdata,info=info};self:set_("conflict")
    log("上传前发现别的设备的存档 rev="..rec.rev.."（本机 rev="..s.rev.."），先不覆盖")
    if self.onConflict then
     local fine,err=pcall(self.onConflict,cdata,info)
     if not fine then log("onConflict 出错："..tostring(err)) end
    end
    return
   end
  end
  local text=self.kit:Encode(data)
  if not text then log("存档编码失败");return fail() end
  local rev=math.max(s.rev,rec and rec.rev or 0)+1
  local touches=self.touches
  local record={rev=rev,device=s.device,at=self.now(),text=text}
  self:call_("上传云存档",function(ev) cloud:Set(self.key,record,ev) end,function(ok2)
   if not ok2 then return fail() end
   self.busy=false
   if self.data()~=data then return self:set_("idle") end
   s.rev=rev
   -- 上传期间又存过档：本机比云端新，脏标记留着
   if self.touches==touches then s.dirty=false end
   self.conflict=nil;self.at=record.at
   log("上传成功 rev="..rev.." 大小 "..#text.." 字节")
   local fine,err=pcall(self.save)
   if not fine then log("写本地出错："..tostring(err)) end
   self:set_("ok")
  end)
 end)
 return true
end

-- 每帧调：判断超时；本机有新进度时每 gap 秒上传一次（出错后也按这个间隔重试；有冲突时停）。
function CloudSync:Update(dt)
 self.t=self.t+(dt or 0)
 local late={}
 for req in pairs(self.inflight) do if self.t>=req.deadline then late[#late+1]=req end end
 for _,req in ipairs(late) do log("请求超时");req.finish(false,"timeout") end
 self.timer=self.timer+(dt or 0)
 if self.timer>=self.gap then
  self.timer=0
  local d=self.data()
  if not self.busy and not self.conflict and type(d)=="table" and type(d.sync)=="table" and d.sync.dirty then self:Push() end
 end
end

-- 给界面看的状态：state 为 off（没登录）/ idle / busy / ok / error / conflict；at 为上次同步成功的时间（os.time）。
-- conflict 时 data、info 是云端那份，玩家点「处理」时拿来弹窗。
function CloudSync:Status()
 local state=self.state
 if not self:cloud_() or not self:uid_() then state="off" end
 local c=self.conflict
 return {state=state,at=self.at,data=c and c.data,info=c and c.info}
end

return CloudSync
