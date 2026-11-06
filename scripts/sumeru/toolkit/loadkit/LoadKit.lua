-- 通用资源分包下载 toolkit：按名字登记资源包，按需确保就绪，空闲时在后台顺序预取。
-- 每个包切成小批分别下载：某一批失败或卡住只重下这一批，重试用完才算失败；重试倒计时与卡住检测靠每帧 Update(dt)。
---@class SumeruLoadOptions
---@field batch integer 每批文件数
---@field parallel integer 同一个包最多同时下载的批数
---@field retries integer 每批失败后自动重试的次数
---@field backoff number[] 第 n 次重试前等待的秒数，超出取最后一项
---@field stall number 一批多少秒没有任何进度算卡住；同一批每卡住一次窗口翻倍
---@field downloader table|nil 下载器，需有 DownloadResources / CancelDownloadGroup；默认引擎的 cache，测试时可换成假的

---@class SumeruLoadBatch
---@field index integer
---@field refs string[]
---@field state string idle / loading / wait / ready / failed
---@field done integer
---@field total integer
---@field failed integer
---@field attempts integer
---@field stalls integer
---@field token integer
---@field group integer
---@field idle number 距上次进度回调的秒数
---@field wait number 重试前剩余等待秒数

---@class SumeruLoadPack
---@field name string
---@field refs string[]
---@field state string idle / loading / ready / failed
---@field done integer
---@field total integer
---@field failed integer
---@field retries integer 本轮自动重试次数
---@field batches SumeruLoadBatch[]|nil
---@field pumping boolean
---@field again boolean

---@class SumeruLoadRequest
---@field names string[]
---@field packs SumeruLoadPack[]
---@field started table<SumeruLoadPack,boolean>
---@field handlers table
---@field done boolean

---@class SumeruLoadKit
---@field opt SumeruLoadOptions
---@field packs table<string,SumeruLoadPack>
---@field requests SumeruLoadRequest[]
---@field queue string[]
---@field prefetching SumeruLoadPack|false
---@field lastFailed SumeruLoadRequest|false
---@field ticking boolean 是否有人每帧调用 Update；没有时失败立即重试、不做卡住检测
local Kit={};Kit.__index=Kit

---@type SumeruLoadOptions
Kit.DEFAULT={batch=16,parallel=2,retries=3,backoff={1,2,4},stall=20}

-- 创建独立的分包下载实例；资源清单由业务层注入。opt 按项覆盖 Kit.DEFAULT。
---@param opt? SumeruLoadOptions
function Kit.new(opt)
 local self=setmetatable({},Kit);self:init(opt);return self
end

-- 初始化参数、资源包表、等待中的请求和后台预取队列。
function Kit:init(opt)
 self.opt={}
 for k,v in pairs(Kit.DEFAULT) do self.opt[k]=v end
 for k,v in pairs(opt or {}) do self.opt[k]=v end
 self.packs={};self.requests={};self.queue={}
 self.prefetching=false;self.lastFailed=false;self.ticking=false
end

-- 登记或替换一个资源包；同包内重复路径只保留一份。
function Kit:Define(name,refs)
 local seen={};local list={}
 for _,path in ipairs(refs or {}) do
  if not seen[path] then seen[path]=true;list[#list+1]=path end
 end
 self.packs[name]={name=name,refs=list,state="idle",done=0,total=#list,failed=0,retries=0,batches=nil,pumping=false,again=false}
end

-- 当前下载器：参数里给了就用它，否则用引擎的 cache。
function Kit:downloader_() return self.opt.downloader or cache end

-- 让一批之后到达的回调全部作废；正在下载的顺带取消。
function Kit:drop_(batch)
 batch.token=batch.token+1
 if batch.state=="loading" and batch.group>0 then self:downloader_():CancelDownloadGroup(batch.group) end
 batch.group=0
end

-- 取消进行中的下载并清空请求与预取队列；之后到达的回调全部丢弃。
function Kit:Stop()
 for _,pack in pairs(self.packs) do
  if pack.state=="loading" then
   for _,b in ipairs(pack.batches or {}) do self:drop_(b) end
   pack.state="idle";pack.batches=nil
  end
 end
 self.requests={};self.queue={};self.prefetching=false;self.lastFailed=false
end

-- 查询资源包是否已全部下载完成。
function Kit:IsReady(name)
 local pack=self.packs[name]
 return pack~=nil and pack.state=="ready"
end

-- 确保若干资源包就绪：已全部就绪时同步回调 onReady；否则按 names 的顺序逐包下载缺失的包并汇总进度。
-- onFail 第二个参数是这次请求里各包自动重试的总次数；onRetry(包名, 该包第几次自动重试) 在每次自动重试时回调。
---@param names string[]
---@param handlers? {onReady:fun()?, onProgress:fun(completed:integer,total:integer)?, onFail:fun(failedCount:integer,retries:integer)?, onRetry:fun(pack:string,attempt:integer)?}
function Kit:Ensure(names,handlers)
 handlers=handlers or {}
 ---@type SumeruLoadRequest
 local req={names=names,packs={},started={},handlers=handlers,done=false}
 for _,name in ipairs(names) do
  local pack=assert(self.packs[name],"Unknown load pack: "..tostring(name))
  if pack.state~="ready" then req.packs[#req.packs+1]=pack end
 end
 if #req.packs==0 then
  if handlers.onReady then handlers.onReady() end
  return
 end
 print("[LoadKit] Ensure "..table.concat(names,","))
 self.requests[#self.requests+1]=req
 self:Settle(req)
end

-- 追加后台预取；只在没有 Ensure 等待时启动，每次只下载一个包。
---@param names string[]
function Kit:Prefetch(names)
 for _,name in ipairs(names) do
  if self.packs[name] then self.queue[#self.queue+1]=name end
 end
 self:Pump()
end

-- 重放最近一次失败的 Ensure 请求：已下完的批次不再请求，失败的批次重试次数清零。
function Kit:Retry()
 local req=self.lastFailed
 if not req then return false end
 self.lastFailed=false
 self:Ensure(req.names,req.handlers)
 return true
end

-- 每帧调用：推进重试倒计时，检测卡住的批次。dt 过大（切后台回来）时按 1 秒算，避免误判卡住。
-- 调过一次（哪怕 dt=0）就认为有人每帧推进，之后失败按 backoff 等待；所以开始下载前可先 Update(0)。
---@param dt number
function Kit:Update(dt)
 self.ticking=true
 local step=math.min(math.max(dt or 0,0),1)
 for _,pack in pairs(self.packs) do
  if pack.state=="loading" and pack.batches then
   local changed=false
   for _,b in ipairs(pack.batches) do
    if pack.state~="loading" then break end
    if b.state=="wait" then
     b.wait=b.wait-step
     if b.wait<=0 then b.state="idle";changed=true end
    elseif b.state=="loading" then
     b.idle=b.idle+step
     local limit=self.opt.stall*2^b.stalls
     if b.idle>=limit then
      print(string.format("[LoadKit] %s 第 %d/%d 批 %.0f 秒没有进度，取消重下",pack.name,b.index,#pack.batches,limit))
      self:drop_(b);b.stalls=b.stalls+1
      self:batchFailed_(pack,b,b.total-b.done)
     end
    end
   end
   if changed then self:advance_(pack) end
  end
 end
end

-- 把包切成批；重试时保留已下完的批次，失败的批次清零重来。
---@param pack SumeruLoadPack
function Kit:prepare_(pack)
 if pack.batches and pack.state=="failed" then
  for _,b in ipairs(pack.batches) do
   if b.state~="ready" then b.state="idle";b.done=0;b.failed=0;b.attempts=0;b.stalls=0 end
  end
  return
 end
 pack.batches={}
 local size=math.max(1,self.opt.batch)
 for i=1,#pack.refs,size do
  local refs={}
  for j=i,math.min(i+size-1,#pack.refs) do refs[#refs+1]=pack.refs[j] end
  pack.batches[#pack.batches+1]={index=#pack.batches+1,refs=refs,state="idle",done=0,total=#refs,failed=0,attempts=0,stalls=0,token=0,group=0,idle=0,wait=0}
 end
end

-- 开始下载单个资源包。
---@param pack SumeruLoadPack
function Kit:Start(pack)
 self:prepare_(pack)
 pack.state="loading";pack.failed=0;pack.retries=0
 if #pack.refs==0 then return self:Finish(pack,true,0) end
 local left=0
 for _,b in ipairs(pack.batches or {}) do if b.state~="ready" then left=left+1 end end
 print("[LoadKit] Start "..pack.name.." ("..#pack.refs.." refs, "..left.."/"..#pack.batches.." batches)")
 self:advance_(pack)
end

-- 下载一批；旧回调通过 token 丢弃。本地预览时回调可能在调用返回前就同步到达。
---@param pack SumeruLoadPack
---@param b SumeruLoadBatch
function Kit:startBatch_(pack,b)
 b.token=b.token+1;local token=b.token
 b.state="loading";b.done=0;b.idle=0
 local group=self:downloader_():DownloadResources(b.refs,function(success,failedCount)
  if b.token~=token then return end
  b.token=b.token+1;b.group=0
  if success then
   b.state="ready";b.done=b.total;b.failed=0
   self:advance_(pack)
  else
   self:batchFailed_(pack,b,failedCount)
  end
 end,function(completed,total)
  if b.token~=token then return end
  b.done=math.min(completed,b.total);b.idle=0
  self:Progress(pack)
 end)
 if b.token==token then b.group=group or 0 end
end

-- 一批失败（含卡住被取消）：还有重试次数就排队重下（有 Update 时先等 backoff），否则记为失败。
---@param pack SumeruLoadPack
---@param b SumeruLoadBatch
function Kit:batchFailed_(pack,b,failedCount)
 b.done=0
 if b.attempts<self.opt.retries then
  b.attempts=b.attempts+1;pack.retries=pack.retries+1
  local wait=self.ticking and (self.opt.backoff[math.min(b.attempts,#self.opt.backoff)] or 0) or 0
  print(string.format("[LoadKit] %s 第 %d/%d 批失败（%s 项），%g 秒后第 %d 次重试",pack.name,b.index,#pack.batches,tostring(failedCount),wait,b.attempts))
  if wait>0 then b.state="wait";b.wait=wait else b.state="idle" end
  -- 先报一次当前进度（这批已清零），再回调 onRetry：调用方据此判断「重试之后进度有没有再前进」。
  for _,req in ipairs(self.requests) do
   for _,p in ipairs(req.packs) do
    if p==pack then self:Report(req);if req.handlers.onRetry then req.handlers.onRetry(pack.name,pack.retries) end;break end
   end
  end
 else
  b.state="failed";b.failed=math.max(1,math.tointeger(failedCount) or 0)
 end
 self:advance_(pack)
end

-- 补足并行的批次；全部批次结束后结算整包。回调同步到达时不重入，由外层循环再走一遍。
---@param pack SumeruLoadPack
function Kit:advance_(pack)
 if pack.pumping then pack.again=true;return end
 pack.pumping=true
 repeat
  pack.again=false
  if pack.state~="loading" then break end
  local busy=0
  for _,b in ipairs(pack.batches or {}) do if b.state=="loading" or b.state=="wait" then busy=busy+1 end end
  for _,b in ipairs(pack.batches or {}) do
   if pack.state~="loading" or busy>=self.opt.parallel then break end
   if b.state=="idle" then busy=busy+1;self:startBatch_(pack,b) end
  end
  if pack.state=="loading" and not pack.again then
   local open,failed=false,0
   for _,b in ipairs(pack.batches or {}) do
    if b.state=="failed" then failed=failed+b.failed elseif b.state~="ready" then open=true end
   end
   if not open then
    pack.pumping=false
    return self:Finish(pack,failed==0,failed)
   end
   self:Progress(pack)
  end
 until not pack.again
 pack.pumping=false
end

-- 资源包下载结束：更新状态，结算相关请求，再继续后台预取。
---@param pack SumeruLoadPack
function Kit:Finish(pack,success,failedCount)
 pack.state=success and "ready" or "failed";pack.failed=success and 0 or (failedCount or 0)
 pack.done=0
 for _,b in ipairs(pack.batches or {}) do if b.state=="ready" then pack.done=pack.done+b.total end end
 if success then pack.done=pack.total end
 print("[LoadKit] "..pack.name.." ready="..tostring(success).." failed="..tostring(pack.failed).." retries="..pack.retries)
 if self.prefetching==pack then self.prefetching=false end
 local pending={}
 for _,req in ipairs(self.requests) do pending[#pending+1]=req end
 for _,req in ipairs(pending) do self:Settle(req) end
 self:Pump()
end

-- 推进请求：按顺序开下一个还没轮到的包；全部结束后回调，任一包失败则记为可重试的失败请求。
-- 前面的包失败不影响后面的包继续下载，这样重试时只剩失败的批次。
---@param req SumeruLoadRequest
function Kit:Settle(req)
 if req.done then return end
 local failed,retries,loading,nextPack=0,0,false,nil
 for _,pack in ipairs(req.packs) do
  if pack.state=="loading" then loading=true;req.started[pack]=true
  elseif pack.state~="ready" then
   if req.started[pack] then failed=failed+math.max(1,pack.failed);retries=retries+pack.retries
   elseif not nextPack then nextPack=pack end
  else retries=retries+pack.retries end
 end
 if loading then return self:Report(req) end
 if nextPack then
  req.started[nextPack]=true
  self:Start(nextPack)
  if not req.done then self:Settle(req) end
  return
 end
 req.done=true
 for i=#self.requests,1,-1 do if self.requests[i]==req then table.remove(self.requests,i) end end
 if failed>0 then
  self.lastFailed=req
  if req.handlers.onFail then req.handlers.onFail(failed,retries) end
 elseif req.handlers.onReady then req.handlers.onReady() end
end

-- 进度变化时刷新包含该包的请求。
---@param pack SumeruLoadPack
function Kit:Progress(pack)
 local done=0
 for _,b in ipairs(pack.batches or {}) do done=done+(b.state=="ready" and b.total or b.done) end
 pack.done=done
 for _,req in ipairs(self.requests) do
  for _,p in ipairs(req.packs) do
   if p==pack then self:Report(req);break end
  end
 end
end

-- 汇总请求内各包的已完成数与总数并回调进度；排在后面还没开始的包按 0 计入总数。
---@param req SumeruLoadRequest
function Kit:Report(req)
 if not req.handlers.onProgress then return end
 local completed,total=0,0
 for _,pack in ipairs(req.packs) do
  completed=completed+(pack.state=="ready" and pack.total or pack.done);total=total+pack.total
 end
 req.handlers.onProgress(completed,math.max(total,1))
end

-- 有 Ensure 等待时让路；否则取队列中下一个未就绪的包在后台下载。
function Kit:Pump()
 if self.prefetching or #self.requests>0 then return end
 while #self.queue>0 do
  local pack=self.packs[table.remove(self.queue,1)]
  if pack and pack.state~="ready" and pack.state~="loading" then
   self.prefetching=pack
   self:Start(pack)
   return
  end
 end
end

return Kit
