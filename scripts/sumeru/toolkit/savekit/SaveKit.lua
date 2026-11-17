-- 通用存档 toolkit：业务只声明带默认值的数据结构；读写后端、版本判断与按结构合并全部在 Kit 内完成。
-- 规则只有一条：先按结构建默认数据，再用存档里同名、同类型的字段覆盖。没有存档、解析失败或版本不同时直接用默认数据。
local LocalBackend=require("sumeru.toolkit.savekit.LocalBackend")
---@class SumeruSaveKit
---@field key string
---@field version integer
---@field schema table
---@field codec table
---@field backend table
---@field lastWritten string|false
---@field writeFailed boolean
local Kit={};Kit.__index=Kit

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

-- 创建存档实例；config 需要 key、version、schema（结构声明）、codec（如 cjson），backend 默认 "local"。
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
 self.lastWritten=false;self.writeFailed=false
end

-- 把存档文本解成完整结构：返回 data,isNew。文本为空、解析失败或版本不同时返回默认数据，isNew=true。
-- 本地读档和云存档（CloudSync）都走这里，规则一致。
function Kit:Decode(text)
 local raw=nil
 if type(text)=="string" then
  local ok,decoded=pcall(self.codec.decode,text)
  if ok and type(decoded)=="table" then raw=integers(decoded) end
 end
 local isNew=raw==nil or raw.version~=self.version
 return merge(self.schema,not isNew and raw or nil),isNew
end

-- 按结构投影后编成存档文本（带版本号）；编码失败返回 nil。
function Kit:Encode(data)
 local root=merge(self.schema,data)
 root.version=self.version
 local ok,text=pcall(self.codec.encode,root)
 if ok and type(text)=="string" then return text end
 return nil
end

-- 读出完整结构交给 done(data,isNew)；本地后端同步回调，云端后端异步回调。
function Kit:Load(done)
 self.backend:read(self.key,function(text) done(self:Decode(text)) end)
end

-- 按结构投影后写出并带上版本号：业务对象上的运行字段不会进存档；内容与上次相同时不重复写，失败只打印一次日志，下一次继续尝试。
function Kit:Save(data)
 local text=self:Encode(data)
 if text and text==self.lastWritten then return true end
 local written=text~=nil and select(2,pcall(self.backend.write,self.backend,self.key,text))==true
 if not written then
  if not self.writeFailed then print("[SaveKit] 存档写入失败："..self.key) end
  self.writeFailed=true;self.lastWritten=false;return false
 end
 self.lastWritten=text;self.writeFailed=false
 return true
end

return Kit
