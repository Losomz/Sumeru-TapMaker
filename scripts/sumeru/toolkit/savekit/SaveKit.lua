-- 通用存档 toolkit：业务只声明带默认值的数据结构；读写后端、版本修补与按结构补全全部在 Kit 内完成。
-- 读档：先按结构建默认数据，再用存档里同名、同类型的字段覆盖（缺的补默认值、多的丢掉）。只有没有存档、解析不了才算新档，
-- 任何时候都不因为版本号把旧档清掉（拾荒日记 1.0.14 把版本 9 升到 10，老玩家一更新就从头开始，见 README“版本修补”）。
-- 版本：没上线时版本号不动，只靠补全；上线后结构变了才加一，需要时在 migrate 里写上一版到这一版的修补，读档时一步步补上来。
-- 意外（修补报错、没有版本号、存档比代码新）：退回按结构补全，原档先留底再写，留着补救的余地。
local LocalBackend=require("sumeru.toolkit.savekit.LocalBackend")
---@class SumeruSaveKit
---@field key string
---@field version integer
---@field migrate table<integer, fun(raw: table)> 版本修补：键是目标版本，函数只管上一版到这一版那一步、只改存档原始表
---@field schema table
---@field codec table
---@field backend table
---@field lastWritten string|false
---@field writeFailed boolean
---@field info SumeruSaveInfo 最近一次 Load 的读档情况
---@field pending {name: string, text: string}|false 第一次写档前要先留底的原档
local Kit={};Kit.__index=Kit

---@class SumeruSaveInfo
---@field from integer|nil 存档里的版本号（解析不了或没写是 nil）
---@field migrated integer[] 这次跑过的修补（目标版本，按顺序）
---@field newer boolean 存档比代码新（比如退了版本）
---@field unexpected string|nil 意外：为什么退回按结构补全；nil 是没有意外

-- 声明种类的私有键，不会与业务字段重名，也不会写进存档。
local KIND={}
-- 后端按名称登记，接口为 read(key,done) / write(key,text)。云存档不是后端：本地照旧是主存档，云端多存一份，见 CloudSync。
local BACKENDS={["local"]=LocalBackend}

-- 声明数组：每个元素都按 item 的结构合并。
function Kit.list(item) return {[KIND]="list",item=item} end

-- 声明任意键的表：每个值都按 item 的结构合并。
function Kit.map(item) return {[KIND]="map",item=item} end

-- 按声明合并一个值：raw 与默认值同类型才覆盖；表按记录、数组、映射逐层处理；raw 为 nil 时得到默认值。
local function merge(decl,raw)
 if type(decl)~="table" then
  if type(raw)==type(decl) then return raw end
  return decl
 end
 if type(raw)~="table" then raw={} end
 local out={};local kind=decl[KIND]
 if kind=="list" then
  for i,value in ipairs(raw) do out[i]=merge(decl.item,value) end
 elseif kind=="map" then
  for key,value in pairs(raw) do out[key]=merge(decl.item,value) end
 else
  for key,value in pairs(decl) do out[key]=merge(value,raw[key]) end
 end
 return out
end

-- 按声明新建一份默认数据，业务重置某个分区时也用它。
function Kit.build(decl) return merge(decl,nil) end

-- JSON 不区分整数与小数：解码后把值为整数的数字还原为 integer。
local function integers(value)
 if type(value)=="number" then return math.tointeger(value) or value end
 if type(value)=="table" then for key,item in pairs(value) do value[key]=integers(item) end end
 return value
end

-- 深拷贝存档原始表：修补在副本上做，半路报错时原档不受影响。
local function copy(value)
 if type(value)~="table" then return value end
 local out={}
 for key,item in pairs(value) do out[key]=copy(item) end
 return out
end

-- 从 from 一步步修补到 to：每一步是 steps[目标版本]，没写的那步跳过。返回修补后的副本和跑过的步；某一步报错返回 nil 和原因。
local function migrate(raw,from,to,steps)
 local out=copy(raw);local done={}
 for v=from+1,to do
  local fn=steps[v]
  if fn then
   local ok,err=pcall(fn,out)
   if not ok then return nil,done,string.format("第 %d 版的修补报错：%s",v,tostring(err)) end
   done[#done+1]=v
  end
 end
 return out,done
end

-- 创建存档实例；config 需要 key、version、schema（结构声明）、codec（如 cjson），backend 默认 "local"；
-- migrate 可选：{[目标版本]=function(raw) ... end}，上线后结构改了才写，只加字段的版本不用写。
function Kit.new(config)
 local self=setmetatable({},Kit);self:init(config);return self
end

-- 初始化后端与写入缓存；未登记的后端直接报错，不静默换成其他存储。
function Kit:init(config)
 self.key=assert(config.key,"SaveKit: missing key")
 self.version=assert(math.tointeger(config.version),"SaveKit: version must be an integer")
 self.schema=assert(config.schema,"SaveKit: missing schema")
 self.codec=assert(config.codec,"SaveKit: missing codec")
 local backend=config.backend or "local"
 self.backend=assert(BACKENDS[backend],"SaveKit: backend not implemented: "..tostring(backend)).new()
 self.migrate=config.migrate or {}
 for v,fn in pairs(self.migrate) do
  assert(math.tointeger(v) and v>=1 and v<=self.version and type(fn)=="function","SaveKit: migrate 的键是 1…version 的版本号、值是函数")
 end
 self.lastWritten=false;self.writeFailed=false;self.pending=false
 self.info={from=nil,migrated={},newer=false}
end

-- 把存档文本解析成原始表；文本为空或解析不了返回 nil。
function Kit:Parse(text)
 if type(text)~="string" then return nil end
 local ok,decoded=pcall(self.codec.decode,text)
 if ok and type(decoded)=="table" then return integers(decoded) end
 return nil
end

-- 存档文本里写的版本号；解析不了或没写返回 nil。
function Kit:VersionOf(text)
 local raw=self:Parse(text)
 return raw and math.tointeger(raw.version) or nil
end

-- 把存档文本解成完整结构：返回 data,isNew,info。只有文本为空或解析不了才返回默认数据、isNew=true。
-- 版本比代码旧：按 migrate 一步步修补再补全；版本相同：直接补全；没有版本号、比代码新、修补报错是意外，原档直接按结构补全，原因记在 info.unexpected。
-- 本地读档和云存档（CloudSync）都走这里，规则一致。
function Kit:Decode(text)
 ---@type SumeruSaveInfo
 local info={from=nil,migrated={},newer=false}
 local raw=self:Parse(text)
 if raw==nil then return merge(self.schema,nil),true,info end
 local v=math.tointeger(raw.version)
 info.from=v
 if v==nil then
  info.unexpected="存档没有版本号"
 elseif v>self.version then
  info.newer=true
  info.unexpected=string.format("存档版本 %d 比代码的 %d 新",v,self.version)
 elseif v<self.version then
  local out,done,err=migrate(raw,v,self.version,self.migrate)
  info.migrated=done
  if out then raw=out else info.unexpected=err end
 end
 if info.unexpected then print("[SaveKit] 读档意外："..info.unexpected.."，按结构补全，原档写档前留底") end
 return merge(self.schema,raw),false,info
end

-- 按结构投影后编成存档文本（带版本号）；编码失败返回 nil。
function Kit:Encode(data)
 local root=merge(self.schema,data)
 root.version=self.version
 local ok,text=pcall(self.codec.encode,root)
 if ok and type(text)=="string" then return text end
 return nil
end

-- 读出完整结构交给 done(data,isNew,info)；本地后端同步回调。
-- 版本和代码不同或出了意外，记下原档，第一次写档前先另存一份（<key>.v<版本>.bak；意外的再带时间，不会被后面的盖掉）。
function Kit:Load(done)
 self.backend:read(self.key,function(text)
  local data,isNew,info=self:Decode(text)
  self.info=info;self.pending=false
  if not isNew and (info.unexpected or info.from~=self.version) then
   local tag="v"..tostring(info.from or "x")
   if info.unexpected then tag=tag.."."..os.time() end
   self.pending={name=self.key.."."..tag..".bak",text=text}
  end
  done(data,isNew,info)
 end)
end

-- 按结构投影后写出并带上版本号：业务对象上的运行字段不会进存档；内容与上次相同时不重复写，失败只打印一次日志，下一次继续尝试。
-- 有待留底的原档时先写留底，留底写不出去就不覆盖原档。
function Kit:Save(data)
 local text=self:Encode(data)
 if text and text==self.lastWritten then return true end
 if text and self.pending then
  local p=self.pending
  local kept=select(2,pcall(self.backend.write,self.backend,p.name,p.text))==true
  if not kept then
   if not self.writeFailed then print("[SaveKit] 原档留底失败，先不覆盖存档："..p.name) end
   self.writeFailed=true;self.lastWritten=false;return false
  end
  print("[SaveKit] 原档留底："..p.name)
  self.pending=false
 end
 local written=text~=nil and select(2,pcall(self.backend.write,self.backend,self.key,text))==true
 if not written then
  if not self.writeFailed then print("[SaveKit] 存档写入失败："..self.key) end
  self.writeFailed=true;self.lastWritten=false;return false
 end
 self.lastWritten=text;self.writeFailed=false
 return true
end

return Kit
