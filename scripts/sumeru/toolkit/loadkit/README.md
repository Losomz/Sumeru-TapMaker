# 资源分包下载 Kit

`require("sumeru.toolkit.loadkit")` 返回通用分包下载器。UrhoX 线上运行时脚本与配置启动前已就绪，图片、声音、字体按需下载（DWP）；本 Kit 在此之上按业务把资源分成包，决定什么时候下哪一包。

```lua
local LoadKit=require("sumeru.toolkit.loadkit")
local loads=LoadKit.new()   -- 可传 {batch=16,parallel=2,retries=3,backoff={1,2,4},stall=20}
loads:Define("core",coreRefs)
loads:Define("level:1",level1Refs)
loads:Define("audio",audioRefs)

-- 首屏：确保必需包就绪，期间显示进度。
loads:Ensure({"core","level:1"},{
    onProgress=function(done,total) ShowProgress(done/total) end,
    onReady=function() EnterGame() end,
    onFail=function(failedCount,retries) ShowRetry() end, -- 重试调用 loads:Retry()
    onRetry=function(pack,attempt) ShowRetrying() end,   -- 某批自动重下
})

-- 每帧推进：自动重试的等待和卡住检测都靠它。
function Update(dt) loads:Update(dt) end

-- 进游戏后后台预取，按顺序每次一个包。
loads:Prefetch({"level:2","audio","level:3"})
```

游戏启动（首屏包、启动页、失败重试）交给 `sumeru.toolkit.bootkit`，它在启动期间替游戏调 `Update`；启动完成后由游戏每帧调。

## 设计

- `Ensure` 只下载未就绪的包；全部已就绪时**同步**回调 `onReady`，调用方不会闪加载遮罩。
- 同一包被多次请求或已在后台预取时合并等待，不重复下载。
- `Prefetch` 在有 `Ensure` 等待时不启动新包，正在预取的单包继续完成；`Ensure` 结束后自动续上队列。
- 预取失败只记日志；之后用到时由 `Ensure` 再次下载，失败可 `Retry()` 重放最近一次失败请求。
- 包状态：`idle` / `loading` / `ready` / `failed`；`IsReady(name)` 查询。
- 本地预览资源已在磁盘上，下载回调立即完成，流程与线上一致。
- **分批**：每包按 `batch`（默认 16）个文件一批，最多同时下 `parallel`（默认 2）批；进度按所有批次汇总，`Stop` 逐批取消。一次 `Ensure` 里的多个包按顺序下，前面的包失败不影响后面的包继续。
- **自动重试**：一批失败后等 `backoff[n]` 秒（默认 1、2、4）只重下这一批，最多 `retries`（默认 3）次；用完仍失败这批才算失败，整包结算后回调 `onFail(失败文件数, 自动重试次数)`。等待期间这批仍占并行位，整体放慢。
- **卡住**：一批 `stall`（默认 20）秒没有任何进度回调，就取消它、换新 token（之后迟到的回调直接丢弃），算一次失败；同一批每卡一次，下次等待时间翻倍，大文件慢网不会被反复误判。
- **`Update(dt)`**：推进重试等待和卡住计时；`dt` 按最多 1 秒算，切后台回来不会误判卡住。从没调过 `Update` 时失败立即重试、不做卡住检测，老接法不会卡死；调过一次（哪怕 `Update(0)`）后才按 `backoff` 等待。
- `Retry()` 重放最近一次失败的请求：已下完的批次保留，只重下失败的批次（重试次数清零）。
- `onRetry(包名, 第几次)` 在每次自动重试时回调，回调前会先报一次当前进度；调用方可据此显示「正在重试」，进度再前进时收起。
- **下载器**：默认用全局 `cache`；`LoadKit.DEFAULT.downloader` 或 `new({downloader=…})` 可换成假下载器做测试（实现 `DownloadResources(refs,onComplete,onProgress)` 与 `CancelDownloadGroup(group)`）。
