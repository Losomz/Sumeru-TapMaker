# 发布物料：Maker 与 TapTap 保持一致

TapTap 商店页上的图标、宣传图、封面、截图、视频和文字，都要和项目里的记录保持一致。下面的规则都是踩过坑后核实过的。

## 原理：三处要一致

| 位置 | 存的是什么 | 谁读它 |
|---|---|---|
| ① `docs/publish-materials/` 里的文件 | 上传版图片，文件名固定 | Maker 出包（没有 `dc_publish_sync` 的项目） |
| ② `.project/project.json` | `assets` 的本地路径和 `*_url`；有 `dc_publish_sync` 时，还有 `baseFields` 里的地址 | Maker 管理发布页 |
| ③ TapTap 草稿 | 用 `taptap-cli app get-app-module` 读，`save-changes` 写 | 上线后玩家看到的就是它 |

Maker 有两种表现，看 `project.json` 里有没有 `dc_publish_sync`：

- **没有**（如 doomsday-miner）：出包时把 ① 的文件传到 TapTap，覆盖草稿。只改 ① 和 ② 就行。
- **有**（如 old-street-forge）：这个块是 2026-10-31 在管理发布页点「使用本地资料」之后出现的。
  - 管理发布页显示的是 TapTap 草稿里的图。
  - 点上线时，Maker 把草稿里的地址写回 `assets` 和 `baseFields`，还会删掉本地路径。
  - 所以只改 ① 和 ② 的话，图会被改回旧的。2026-10-31 和 11-01 各发生过一次，两次封面都退回了 Maker 最早生成的 AI 图。
  - 在管理发布页上传图片，或者用页面上的 AI 按钮生成图片，会直接写进 TapTap 草稿。这时 `assets` 的路径会指向 `.project/game_material/`，新地址记在 `dc_publish_sync.pending` 里，`synced` 变成 `false`。要留档的话，把图下载到 `docs/publish-materials/`，再改回本地路径。

不管是哪种，**三处一起改**都不会出错。`dc_publish_sync` 是 Maker 自己的记录：`baseFields` 里的图片地址可以改成和 `assets` 一样，其他字段（`dcVersion`、`dcStatus`、`pending`）不要动。

## 物料清单：放在哪里，对应哪个字段

字段名以 `taptap-cli app get-app-module` 返回的为准。要说「TapTap 没有这个字段」之前，先做两件事：

- 读 `taptap-cli skills read taptap-app-edit/references/app-edit-field-map.md`；
- 把所有模块都读一遍：`basic-info`、`assets-upload`、`windows-exclusive`、`profile-promotion`、`other-settings`。

**封面就在名字看不出来的 `windows-exclusive`（Windows 素材）模块里。**

### 图片

上传版放在 `docs/publish-materials/`，原稿放在 `docs/publish-materials/source/`。

| Maker 页面 | 文件 | `assets` 路径 / 地址 | `baseFields` | TapTap 模块.字段 | 要求 |
|---|---|---|---|---|---|
| 游戏图标 | `icon.png` | `icon` / `icon_url` | `icon_url` | `basic-info.icon`（必填） | 1:1，至少 512×512（建议 1024），方图，不要自己切圆角 |
| 宣传主图 | `promo-banner.jpg` | `promotional_image` / `promotional_image_url` | `banner_url` | `assets-upload.banner_4` | 16:9，至少 1920×1080，不超过 4MB |
| 方形宣传图 | `promo-square.jpg` | `square_promotional_image` / `square_promotional_image_url` | `square_promo_url` | `assets-upload.square_promo_image`（必填） | 1:1，至少 1440×1440，不超过 4MB（PNG 容易超，用 JPG） |
| 横版封面 | `cover-horizontal.jpg` | `cover_horizontal` / `cover_horizontal_url` | `cover_horizontal_url` | `windows-exclusive.cover` | **460:215**（如 1472×688），至少 460×215，带游戏名 |
| 竖版封面 | `cover-vertical.jpg` | `cover_vertical` / `cover_vertical_url` | `cover_vertical_url` | `windows-exclusive.cover_vertical`（必填） | **2:3**（如 1080×1620），至少 600×900，带游戏名 |
| 游戏截图 | `screenshot-1.jpg` … | `screenshots` / `screenshot_urls` | `screenshot_urls` | `assets-upload.screenshots` | 实机截图，至少 3 张 |

注意：两张封面**不是** 16:9 和 9:16。直接拿宣传主图当横版封面，比例是错的。

### 视频

视频只存在 TapTap 上，Maker 不管。文件放在 `docs/publish-materials/video/`。视频文件很大，提不提交由项目自己定；拿到的 `videoId` 一定要记进 README。

| TapTap 模块.字段 | 要求 |
|---|---|
| `assets-upload.trailer` 宣传片 | 只收横屏 16:9，至少 1280×720，至少 15 秒；首页推荐和详情页都会用 |
| `assets-upload.gameplay_demo_video` 实机录屏 | 比例在 9:21 到 21:9 之间，至少 540×540，时长 15 秒到 30 分钟。前 5 秒内就要展示核心玩法，并且至少持续 10 秒。不能有人声配音和字幕，不能有画中画或手机界面 |

### 文字

| Maker 页面 | `project.json` | TapTap 模块.字段 | 要求 |
|---|---|---|---|
| 游戏名称 | `taptap_publish.title` | `basic-info.title` | 1 到 50 字 |
| 游戏简介 | `taptap_publish.description` | `basic-info.description` | 写清核心玩法 |
| 游戏类型 | `taptap_publish.category` | `basic-info.category` | 必填 |
| 开发者的话 | `taptap_publish.trial_note` | Maker 管 | — |
| 首页推荐语 | — | `profile-promotion.promotion_text` | 不超过 25 字 |
| 首页推荐素材 | — | `profile-promotion.promotion_material_type` | 宣传图、实机演示、预告片三选一 |
| 论坛更新公告 | `docs/更新日志/` | — | 见那个目录的 README |

## 换图步骤

1. **导出上传版**：原稿放进 `source/`，按上表的比例导出上传版，覆盖同名文件。比例不对就从原稿裁，不要拉伸；裁之前确认游戏名和主体不会被切掉。
2. **上传拿地址**：运行 `taptap-cli upload docs/publish-materials/<文件> --dev-id <D> --app-id <A> --yes`，返回的 `data.url` 就是新地址。如果两个文件内容完全相同，第二次上传会报 409（幂等键冲突），直接用第一次的地址。
3. **写进 TapTap 草稿**：
   - 用 `taptap-cli app list-app-versions` 看有没有「未发布」的草稿。没有就运行 `taptap-cli app create-draft --dev-id <D> --app-id <A> --data '{}' --yes`。
   - 用 `get-app-module` 读出字段当前的值，写成 `changes.json`（文件要放在当前目录下）：
     ```json
     {"changes":[{"field_id":"cover_vertical","value":{"url":"<新地址>","info":{"width":1080,"height":1620,"size":618812,"format":"jpg"}},"expected":"<当前值>"}]}
     ```
   - 运行 `taptap-cli app save-changes --dev-id <D> --app-id <A> --data @changes.json --idempotency-key <不重复的键> --yes`，再用 `get-app-module` 读回来核对。
   - 视频也是这样写：先用 `taptap-cli asset-library +upload-video <文件> --dev-id <D> --app-id <A> --yes` 拿到 `videoId`，值直接写数字。视频还在审核中（`regulating`）时也能写入。
4. **改 `project.json`**：`assets` 的本地路径指向 `docs/publish-materials/`，`*_url` 填新地址；有 `dc_publish_sync` 的项目，`baseFields` 里对应的地址也改成同一个。
5. **检查后推送**：运行 `publish-check.ps1 -Remote`，没有错误和警告再推送（用 Maker 构建）。
6. **上线**：用 Ctrl+F5 刷新 Maker 管理发布页，**每一张图都看一遍**，全对了再点上线。
7. **上线后核对**：再跑一次 `-Remote`，并看 Maker 的同步提交有没有把 `project.json` 里的图改回去。改回去了就回到第 3 步。

## 规则

1. **图片统一放 `docs/publish-materials/`**，文件名用上表的固定英文名。这个目录不在资源根下，不会打进游戏包。
2. **三处一起改**（见上面的「原理」），不要只改其中一处，也不要只在 TapTap 后台改。
3. **本地路径不能删**：删掉 `icon`，管理发布会报「assets 缺少 icon 字段」，没法上传。被 Maker 同步删掉的，要补回来。
4. **自己的图不要放进 `_uploads/`**：Maker 同步时会删掉它不认识的文件，只保留在 Maker 网页上传过的。
5. **`game_material/` 不能提交**：Maker 远端会拒绝推送。它下面多半是 Maker 最早生成的 AI 图。
6. **不要随手点管理发布页的「使用本地资料」**：old-street-forge 点过之后，图片路径被改回 `game_material/` 里的旧 AI 图，`project.json` 里还多出了 `dc_publish_sync`。
7. **截图只用实机截图**：不要用 AI 生成的截图。
8. **版本号不用手动改**：Maker 每次同步都会把 `version` 加 1。
9. **推送被拒怎么办**：如果报 `push-to-checkout hook declined`，而远端又没有新提交，说明 Maker 云端有一份没提交的 `project.json`（管理发布页写的发布记录）。处理步骤（`maker.js` 在 `~/.taptap-maker/mcp-runtime/<版本>/dist/`）：
   ```
   node <maker.js> git cloud-status --target-dir <项目>
   node <maker.js> git cloud-diff --target-dir <项目>
   node <maker.js> git cloud-commit --target-dir <项目> --message "管理发布页的未提交改动" .project/project.json
   git fetch origin && git merge origin/main
   ```
   - diff 里只有发布记录（`dcVersion`、`dcStatus`、`updated_at` 等）时，直接提交。如果它把图片改成了旧图，先和用户确认。
   - 合并时保留自己的图片地址，然后重新构建。

## 做物料要注意

- **缩小后要认得出**：图标和封面在首页卡片里会被缩得很小，人物、武器这类主体和游戏名都要够大，缩到 1/4 还能认出来。
- **色调统一，但不要一片同色**：old-street-forge 的第二版整套偏红，首页点击率低于平台均值。第三版改成蓝夜加金光。
- **看清有没有字的要求**：标着「含 Logo」的（两张封面）要带游戏名；标着「禁止包含文字」的（游戏库背景壁纸、无 Logo 宣传图）不能有任何字。
- **同一构图出多个比例**：从高清原稿裁，不要拉伸。
- **视频**：宣传片只收横屏，实机录屏不能加字幕和配音。
- **数字要跟着改**：改了玩法数值，回头看一眼简介、宣传图和截图里的数字是不是还对。

## 检查脚本会拦下的问题

`publish-check.ps1` 只读，不会改任何文件。它会报出下面这些问题：

- `icon` 为空（出包会失败）。
- 路径指向 `game_material/`（多半是旧 AI 图）。
- 路径指向自己放进 `_uploads/` 的文件（会被 Maker 删掉）。
- 文件不存在，或者尺寸、比例、大小不合要求（见上面的物料清单）。两张封面的比例是 460:215 和 2:3。
- `*_url` 打不开，或者和本地文件尺寸不一样。
- 有 `dc_publish_sync` 时，`baseFields` 里的图片地址和 `assets` 不一致。这说明新图没写进 TapTap 草稿，上线时会被改回去。
- 加 `-Remote` 时：TapTap 草稿里的图标、宣传图、方图、两张封面、标题、简介、类型，有和 `project.json` 不一致的。

## 模板

首次同步时，`setup.ps1` 会在项目里补齐下面两个目录；已经有了就不动：

- `docs/publish-materials/`：发布物料目录，里面有目录结构、字段对照和当前状态表。
- `docs/更新日志/`：论坛更新公告，按版本分目录，带写作模板。
