# 通用存档 Kit

`require("sumeru.toolkit.savekit")` 返回通用存档管理器。Kit 负责读写后端、JSON 编解码、版本判断以及按结构合并。业务层只声明一份带默认值的数据结构。云存档见 [云存档（CloudSync）](#云存档cloudsync)。

```lua
local SaveKit=require("sumeru.toolkit.savekit")
local list,map=SaveKit.list,SaveKit.map

local schema={
    player={crystal=0,research=map(0),slots=list(false)},
    run={wave=1,gold=0,towers=list({kind="basic",level=1,lines=map(0)})},
}

local kit=SaveKit.new({key="game.json",version=1,schema=schema,codec=cjson,backend="local"})
kit:Load(function(data,isNew) --[[ data 一定是完整结构 ]] end)
kit:Save(data)
```

## 结构声明

- 普通值：默认值同时规定类型，如 `gold=0`、`guide="grab"`、`active=false`。
- 嵌套表：作为记录，按字段逐层合并。
- `SaveKit.list(item)`：数组，每个元素都按 `item` 合并。
- `SaveKit.map(item)`：任意键的表，每个值都按 `item` 合并。
- `SaveKit.build(decl)`：按声明新建一份默认数据，业务重置某个分区时使用。

## 读档规则

**读档永远不清档。** 只有没有存档、或 JSON 解析不了，才返回默认数据、`isNew=true`。版本号对不上不算新档。

- 先按结构建一份默认数据，再用存档里同名且同类型的字段覆盖。
- 结构里没有的字段直接丢弃，类型不同的字段保留默认值，缺的字段补默认值。
- JSON 不区分整数与小数，解码后值为整数的数字统一还原为 integer。
- `Decode` / `Load` 返回 `data, isNew, info`。`info.from` 是存档里的版本号，`info.migrated` 是这次跑过的修补，`info.newer` 表示存档比代码新，`info.unexpected` 是意外的原因（没有意外是 `nil`）。

## 版本修补

存档管理分三种情况：

| 情况 | 怎么做 |
|---|---|
| 没上线 | 只走上面的默认补全，`version` 不动，不写修补。 |
| 上线后 | 结构变了 `version` 才加一。只加字段不用写修补；改名、改类型、拆字段、挪位置才在 `migrate` 里写上一版到这一版那一步。 |
| 意外 | 修补报错、存档没有版本号、存档比代码新（比如退了版本）：不清档，用原档直接按结构补全，原档先留底再写。 |

```lua
SaveKit.new({
 key="save.json", version=11, schema=Schema.root, codec=cjson,
 migrate={
  -- 键是目标版本：10 的档读进来时跑 [11]，9 的档先跑 [10]（没写就跳过）再跑 [11]
  [11]=function(raw)
   raw.player=raw.player or {}
   raw.player.coins=raw.money; raw.money=nil   -- 改名：旧字段挪过去
  end,
 },
})
```

- 修补只改存档的原始表（JSON 解出来的），不调游戏系统、不读配置表，以后配置改了修补照样能跑。
- 修补在副本上做，某一步报错就整个丢掉，用原档直接补全，原因记在 `info.unexpected` 并打日志。
- 写过的修补永远不删：玩家可能隔好几个版本才更新。
- **留底**：读进来的版本和代码不同、或出了意外，Kit 记下原文；第一次写档前先把原文另存为 `<key>.v<版本>.bak`（意外的再带上时间，不会被后面的盖掉），留底写不出去就不覆盖原档。出了问题从留底里还能救。
- 发版前用上一版的真存档跑一遍读档（拾荒日记的 T104）。发布流水线第 6 步会查：存档版本号比上一版变了，或者没有上一版的存档样本，就不让构建。
- 教训：拾荒日记 1.0.14 只加了三个字段，却把版本 9 升到 10，旧规则“版本不同按新档”让老玩家一更新就从第 1 天开始，只好紧急退版本。

## 写档

- `Save(data)` 先按结构投影再写出，根节点的 `version` 由 Kit 写入。结构外的字段不会写进存档，所以业务对象可以同时挂存档字段和运行字段，直接拿去保存。
- 内容与上次写出的相同时不重复写。
- 写入失败只打印一次日志、返回 `false`，下一次保存继续尝试，不影响游戏。
- 有待留底的原档时，先写留底再写存档（见“版本修补”）。
- `Encode(data)` / `Decode(text)` 只编解码、不读写，规则和 `Save` / `Load` 相同（`Decode` 返回 `data, isNew, info`）。`Parse(text)` 只解析成原始表，`VersionOf(text)` 取文本里的版本号。云存档用它们处理云端那份文本。

## 与框架 Model 配合

推荐把 Kit 注册为 System，再由业务的 Model 持有读出的数据。框架初始化时读一次，之后业务直接修改 Model，保存时把 Model 整份交给 Kit：

```lua
arch:RegisterSystem("SaveKit",function() return SaveKit.new{...} end)
arch:RegisterModel("GameModel",function() return GameModel.new() end)
arch:GetModel("GameModel"):Load(function() --[[ 数据到位后再创建业务 ]] end)
```

Model 内部通过 `self:GetSystem("SaveKit")` 存取，不直接接触文件或云端。

## 后端

- `local`：引擎沙箱内的单个文件，读取完成后同步回调。
- 新后端只需实现 `read(key,done)` 和 `write(key,text)`，然后登记到 `SaveKit.lua` 的 `BACKENDS`。`Load` 统一使用回调，异步后端不用改业务层。
- 传入未登记的后端名会直接报错，不会静默换成本地存储。
- 云存档不做成后端，见下一节：本地照旧是主存档，云端多存一份。

## 云存档（CloudSync）

`require("sumeru.toolkit.savekit.CloudSync")` 把整份存档多存一份到 Maker 的 `clientCloud`（values 里的一个 key），用于换手机、重装、手机和 PC 之间接着玩。不需要服务器。

- **本地照旧是主存档。** 没网、没登录、云端出错时游戏照常玩，什么都不丢。
- 云端一条记录 `{rev, device, at, text}`：`text` 是 `Kit:Encode` 编好的存档文本，`rev` 每上传一次加一，`device` 是上传那台设备的随机设备号。
- 存档根节点放一份同步状态 `sync={device, rev, dirty}`：本机设备号、本机基于云端第几版、上传后本机又存过档没有。判定只看这三样，不比设备时间。
- 云端文本走 `Kit:Decode`，修补、补全和本地读档完全一样。云端是旧版本的照样修补后用；云端是比本机代码新的版本（别的设备装了新版）不用，本机也不往上覆盖，免得丢新字段。
- 读写都是异步的。所有回调只认一次，超时、迟到、重复的回调都丢掉；SDK 调用包在 `pcall` 里，出错打 `[CloudSync]` 日志。

### 规则

启动时（`Check`）：

| 情况 | 用哪份 |
|---|---|
| 没登录、读失败、超时、云端没有、解不开、云端存档版本比本机代码新 | 本机 |
| 本机是新档（重装、换手机） | 云端 |
| 云端是本机传的，或云端版本号不比本机新 | 本机 |
| 云端是别的设备传的更新版本，本机上传后没再存过档 | 云端 |
| 云端是别的设备传的更新版本，本机也有新进度 | 冲突：先用本机的进游戏，再让玩家选 |

上传（`Push`）：先读云端，云端是别的设备传的更新版本就**不覆盖**，回调 `onConflict`，暂停自动上传直到玩家选完；云端存档版本比本机代码新时也不覆盖（`force` 也不行）；否则写入 `rev = max(本机, 云端) + 1`，成功后清掉脏标记、写一次本地。上传期间又存过档时脏标记留着。

### 游戏要做的七样

1. **结构里加同步状态**（不用改 `version`，新字段读档时自动补默认值）：
   ```lua
   local CloudSync=require("sumeru.toolkit.savekit.CloudSync")
   Schema.root={player={...},sync=CloudSync.Schema()}
   ```
2. **注册 System**：`data()` 取当前整份存档；`save()` 写本地，**不能经过会标脏的存档入口**（否则上传成功后马上又是脏的）。云变量名上线后不能改。
   ```lua
   arch:RegisterSystem("CloudSync",function()
    return CloudSync.new({kit=arch:GetSystem("SaveKit"),key="save",gap=180,timeout=6,
     data=function() return arch:GetModel("GameModel").data end,
     save=function() arch:GetModel("GameModel"):Save() end})
   end)
   ```
3. **启动加一步**，放在读档之后、创建业务之前；`update` 推进超时。截图、自检场景跳过。
   ```lua
   {label="云存档",
    start=function(step)
     local model=arch:GetModel("GameModel");local sync=arch:GetSystem("CloudSync")
     sync:Check(model.data,model.isNew,function(r)
      if r.use=="cloud" then model.data=sync:Adopt(r.data,r.info);model.isNew=false;model:Save();model.fromCloud=true
      elseif r.use=="conflict" then model.conflict=r end
      step:Done()
     end)
    end,
    update=function(step,dt) arch:GetSystem("CloudSync"):Update(dt) end},
   ```
4. **存档前标脏、每帧推进、切后台上传**：
   ```lua
   function App:Save() self.sync:Touch();self.model:Save() end
   function App:Update(dt) self.sync:Update(dt) end          -- 有新进度时每 gap 秒上传一次
   function App:Focus(focused) if not focused then self:Save();self.sync:Push() end end
   ```
5. **冲突弹窗**：两份摘要（等级、金币、天数，云端带保存时间），「用云端的」「用本机的」两个按钮，点遮罩不关。启动时的冲突在进游戏后弹，上传时发现的冲突由 `onConflict` 弹。
   ```lua
   self.sync.onConflict=function(data,info) self:CloudConflict(data,info) end
   function App:CloudConflict(data,info)
    self:Popup("confirm",{title="云存档",text=summary(data,info,self.p),ok="用云端的",cancel="用本机的",
     fn=function() self:UseCloud(data,info) end,
     onCancel=function() self.sync:Push(true) end})   -- 用本机的：强制覆盖云端
   end
   ```
6. **运行中换档**：选了云端的就把整份数据换掉、重建运行态、关掉页面和弹窗、重新进游戏。和清档共用一个函数。清档时**保留 `sync`**（设备号、版本号），再上传一次，云端也换成新档；否则下次启动会被当成新档把旧进度读回来。
   ```lua
   function App:UseCloud(data,info) self.model.data=self.sync:Adopt(data,info);self.model.isNew=false;self:UseData() end
   function Model:Reset() local sync=self.data.sync;self.data=SaveKit.build(Schema.root);self.data.sync=sync;self:Save() end
   ```
7. **设置页状态**：一行状态加一个「同步」按钮，按 `Status().state` 显示：`ok` 写「已同步 · 时间」，`busy` 同步中，`error` 同步失败稍后重试，`off` 登录后自动同步，`conflict` 云端有另一份存档（按钮变「处理」，点了弹冲突窗）。`onChange` 里刷新界面。

### 接口

| 接口 | 说明 |
|---|---|
| `CloudSync.Schema()` | 同步状态的结构 `{device="",rev=0,dirty=false}` |
| `CloudSync.new(opts)` | `kit`、`key`、`data()`、`save()`；可选 `gap`（定时上传间隔，默认 180 秒）、`timeout`（请求超时，默认 8 秒）、`onConflict(data,info)`、`onChange()`。测试注入：`cloud`（同 `clientCloud`）、`userId`（函数）、`now`（函数） |
| `sync:Check(data,isNew,done)` | 启动判定，`done({use="local"/"cloud"/"conflict", data, info={rev,device,at}})` |
| `sync:Adopt(data,info)` | 接过云端数据：版本号取云端的，设备号留本机的，清掉脏标记；返回 data |
| `sync:Touch()` | 本机存档了：标脏 |
| `sync:Push(force)` | 先读后写；`force` 时不管冲突直接覆盖。正在上传、有冲突（非 force）、没登录时返回 false |
| `sync:Update(dt)` | 每帧调：超时、定时上传（有冲突时不传） |
| `sync:Status()` | `{state, at, data, info}`：`state` 为 off / idle / busy / ok / error / conflict，`at` 为上次同步成功的时间；冲突时 `data`、`info` 是云端那份 |

### 注意

- **冲突要让玩家选，不要按时间自动覆盖。** 两台设备的时钟不可靠，自动选很容易把玩了很久的那份冲掉。
- **限额**：读、写各每分钟 300 次，数据每分钟 48MB。一次上传是一次读加一次写；按默认间隔远用不完。存档大小看日志里的「上传成功 … 字节」。
- **客户端数据可以被改。** 云存档只是备份，不要拿它做付费校验。
- **电脑本地预览**：引擎自带一个模拟云端（用户 ID 1001），只存在内存里，进程退出就清空。所以本地每次启动都读不到云存档，清本地存档照常有效。两台设备的流程要扫测试码在真机上试。
- 引擎的 `SaveScene`/`LoadScene` 是存场景节点用的，不适合 Lua 表存档。引擎文档：`engine-docs/recipes/client-cloud-score.md`。
