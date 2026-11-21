# 发布流水线

发包、更新上架、版本号，全走 `release.js`：步骤顺序和每一步的选项写死在脚本里，发布时不再翻文档临场决定。
每次发布照 [发布清单模板.md](发布清单模板.md) 走，`new` 会复制一份到 `docs/更新日志/<版本>/发布清单.md`。

```
node dev/sumeru/release/release.js <命令> [--version 1.0.N]
```

不带 `--version` 时，操作最新一次发布（`docs/更新日志/` 下版本号最大、有 `发布记录.json` 的那个）。

## 命令和清单步骤

| 命令 | 清单第几步 | 做什么 | 会写什么 |
|---|---|---|---|
| `status` | 随时 | 版本一览：云端和本地的 Maker 版本、代码里的 appVersion、TapTap 最近两个版本、最新的包、详情页按钮（玩家能不能玩）、下一个版本号、进行中的发布 | 只读 |
| `new` | 1 | 同步云端，本次版本 = 云端 `project.json` 的 `version` + 1，建 `docs/更新日志/<版本>/`：`发布清单.md`、`日志.md`（公告稿，模板已填好版本和日期）、`发布记录.json` | 本地文件；云端有发布页写的 `project.json` 时提交掉 |
| `draft` | 2 | 检查公告稿（标题以“【更新公告】v0.N ”开头、没有 `<…>` 占位、有交流群），上传配图，在 TapTap 建草稿（改过稿就改草稿），给出预览链接 | TapTap 草稿（玩家看不到）、社区图片 |
| `approve` | 3 | 开发者看过预览、说可以发之后，记下确认。之后稿子再改，确认自动作废 | 本地记录 |
| `prepare` | 4–6 | 一键备包：同步云端 → 写 appVersion 并单独提交 → 全量测试 → 发布前检查。哪步不过就停 | 本地提交 |
| （构建） | 8 | 先跟开发者说“开始构建，先别开发布页”，再调 Maker MCP 的 `maker_build_current_directory` | 推送、构建 |
| （点发布） | 9 | 开发者把发布页**刷新**（开着的旧页面会把旧简介写回去）→ 确认没红字 → 选「保持状态并更新版本」→ 点一次 | — |
| `finish` | 10–13 | 一键收尾：核对上线 → 发更新公告 → 换活动与公告 → 版本表加一行、提交、出发布报告。还在审核就停在第 10 步（退出码 2），过几分钟重跑 | 论坛帖子、活动与公告、本地提交 |

| `resubmit` | 被拒 | 只改资料（简介等）重提：本地简介写进 TapTap、预检；加 `--yes` 才写入并提审。不回发布页点 | TapTap 资料、提审 |
| `renumber` | 被拒 | 要改代码重建：重建版本号必 +1，整次发布改号（记录目录、清单、版本表），公告照旧；之后 `prepare` → 构建 | 本地提交 |

单步命令（`prepare`、`finish` 里的每一步都能单独跑）：`sync`、`version`、`test`、`check`、`verify`、`post`、`pin`、`record`。

## 定死的规则

- **版本号**：本次 = 云端 `project.json` 的 `version` + 1（Maker 每构建一次把末位加 1）；公告写后两段（1.0.8 → v0.8）；数据后台 `appVersion` 用同一个号。
- **上架状态**：保持“提供游玩”，发布页只点「保持状态并更新版本」。`project.json` 记成公开测试（`release_phase = public_test`），或者详情页按钮不是“试玩 / 开始”这类，检查直接不过。
- **平台**：只上手机（`app_platforms = "1"`）。
- **测试**：`dev/release.json` 里 `test.must` 的每一句都要在日志里出现，断言失败 0 条，运行时汇总的 `lua_errors` 为 0。测的提交和构建前的提交要一样，代码变过就重测。
- **更新公告**：官方身份、“综合”版块（`post.group`）。版本没上线不发；只发开发者确认过、之后没改过的那份草稿（TapTap 要求先给人看预览、点头后才发，不能同一轮建了就发）。
- **活动与公告**：下线旧的更新公告（标题以“【更新公告】”开头的）→ 其他详情页置顶先取消 → 建新公告，置顶照旧公告、展示 `post.pinDays` 天（到那天北京时间 23:59:59）→ 置顶还回去。这样新公告排详情页第一条。公告位满了又没有旧更新公告可换，就停下来请开发者定。
- **审核敏感词**：`check` 查简介，有 `review.words` 里的词就不过；游戏文字里有只提示。简介超过 `review.descMax` 字也提示：简介一类玩法一行，别列店名细节（1.0.10 就因简介里一句“彩票站”被拒）。
- **被拒**：`finish` 记下原因，按要改什么走 `resubmit` 或 `renumber`。
- **云端同步**：发布页写在云端、没提交的 `.project/project.json` 自动提交后合并到本地。云端还有别的没提交的文件就停下来报，不碰。
- **防重复**：每个写操作带固定的防重复键（游戏-版本-动作），进度记在 `发布记录.json`。中途断了重跑同一条命令，做完的部分跳过。
- **记录可以并行写**：`test`、`check` 一跑几分钟，期间跑 `approve` 之类没关系。每条命令写回记录时只写自己改过的字段，别的照磁盘上最新的（1.0.9 时 `test` 跑完写回，冲掉过中途的 `approve`）。
- **密钥**：只用 taptap-cli、Maker 自己存好的登录，不读也不打印密钥；输出里的 git 地址令牌、Bearer、GameAlgo 密钥一律打码。
- **时间**：一律按北京时间显示和计算。

## 每个游戏的配置：`dev/release.json`

TapTap 的 `developer_id`、`app_id`、游戏名从 `.project/project.json` 读，这里只写各游戏不一样的：

```json
{
  "appVersion": [
    { "file": "scripts/data/GameAlgo.lua", "match": "appVersion = \"([0-9.]+)\"" }
  ],
  "test": {
    "entry": "dev/TestBoot.lua",
    "script": "tests/TestLoop.lua",
    "frames": 4000,
    "timeout": 280,
    "must": ["[TestLoop] ALL DONE", "[TestLoop] done"]
  },
  "post": { "group": "0", "pinDays": 30, "mustInclude": ["交流群"] }
}
```

- `appVersion`：数据后台版本号写在哪。`match` 是正则，第一个括号是版本号；可以列多个文件。
- `test`：`entry` 是运行时入口（相对 `scripts/`），`script` 是 `-validate-test` 的测试脚本（相对 `scripts/`），窗口尺寸取 `dev/launch.json`。`frames` 给小了测试会被截停、后面的没跑也显示通过，所以要靠 `must` 里的结束语兜底。
- `post`：可省略，默认就是上面的值。
- `review`：可省略。`words` 敏感词，`descMax` 简介字数提示线（默认 300），`scan` / `skip` 查游戏文字的目录。

## 发布记录：`docs/更新日志/<版本>/发布记录.json`

记本次走到哪一步、每步的结果：上一版的版本号、包号和 TapTap 版本，测试结果，公告草稿和预览链接，确认，上线的 TapTap 版本和包号，帖子链接，活动与公告的编号。`finish` 的最后一步把它和发布清单一起提交。

## 还没做成命令的

- 第 7 步改商店物料：照 [../publish/README.md](../publish/README.md) 做，`check` 里的物料检查会跑 `publish-check.ps1` 兜底。
- 第 14 步看数据后台：用 `gamealgo` 命令行按版本查。
