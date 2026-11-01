# 发布物料

TapTap 商店页用到的所有物料都放在这里。字段对照、尺寸要求、换图步骤见 `dev/sumeru/publish/README.md`。换图要三处一起改：本目录的文件、`project.json`、TapTap 草稿。

## 放在哪里

```
docs/publish-materials/
  README.md              本说明，加上下面的「当前状态」
  icon.png               游戏图标          1:1，1024×1024，方图，不切圆角
  promo-banner.jpg       宣传主图          16:9，1920×1080，不超过 4MB
  promo-square.jpg       方形宣传图        1:1，至少 1440×1440，不超过 4MB
  cover-horizontal.jpg   横版封面          460:215（如 1472×688），带游戏名
  cover-vertical.jpg     竖版封面          2:3（如 1080×1620），带游戏名
  screenshot-1.jpg …     游戏截图          实机截图，至少 3 张
  source/                原稿：高清 PNG、出图提示词，不上传
  video/                 宣传片、实机录屏：大文件，提不提交由项目定
```

- 上面这些是**上传版**，文件名固定；`project.json` 里 `assets` 的本地路径都指向这里。
- 原稿改了以后，从原稿重新导出上传版。比例不对就裁，不要拉伸。
- 这个目录不在资源根下，不会打进游戏包。

## project.json 写法

```json
"assets": {
  "icon": "docs/publish-materials/icon.png",
  "icon_url": "<同一张图上传到 TapTap 后的地址>",
  "promotional_image": "docs/publish-materials/promo-banner.jpg",
  "promotional_image_url": "<同上>",
  "square_promotional_image": "docs/publish-materials/promo-square.jpg",
  "square_promotional_image_url": "<同上>",
  "cover_horizontal": "docs/publish-materials/cover-horizontal.jpg",
  "cover_horizontal_url": "<同上>",
  "cover_vertical": "docs/publish-materials/cover-vertical.jpg",
  "cover_vertical_url": "<同上>"
}
```

如果 `project.json` 里有 `dc_publish_sync`，它下面 `baseFields` 的图片地址也要改成同一个。

## 当前状态

每次换图后在这里更新一行。地址只写最后 8 位就够认了。

| 物料 | 文件 | TapTap 地址 | 草稿 / 线上核对 |
|---|---|---|---|
| 图标 | `icon.png` | | |
| 宣传主图 | `promo-banner.jpg` | | |
| 方形宣传图 | `promo-square.jpg` | | |
| 横版封面 | `cover-horizontal.jpg` | | |
| 竖版封面 | `cover-vertical.jpg` | | |
| 截图 | `screenshot-*.jpg` | | |
| 宣传片 | `video/` | videoId： | |
| 实机录屏 | `video/` | videoId： | |
