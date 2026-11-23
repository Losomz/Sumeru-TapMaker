# dev/sumeru/gamealgo：固定看板和事件词典

各游戏的 GameAlgo 后台照同一个模板生成：五页（概览、留存、广告收入、新用户流程、玩法），事件和字段跟 [TelemetryKit](../../../scripts/sumeru/toolkit/telemetrykit/README.md) 一一对应。随模板同步，项目里不要改。

| 文件 | 作用 |
|---|---|
| `report-pack.template.json` | 固定看板。玩法页三张表：每日玩法次数（按 mode）、区间成败（按玩法）、各关成败（按 mode、level_no、level_name） |
| `events.template.json` | 固定事件词典：`level_start`、`level_end`、`milestone`、`ad_view`、`_boot_begin`、`_boot_ready`、`_boot_fail`、`_boot_retry` |
| `make-pack.js` | 读项目的 `dev/gamealgo/game.json`，生成 `dev/gamealgo/report-pack.json` 和 `events.yaml`（生成物，别手改） |

## 用法（项目根目录）

```bash
node dev/sumeru/gamealgo/make-pack.js
gamealgo events apply dev/gamealgo/events.yaml --json          # 没有试运行，直接提交；先提交词典，看板才认新字段
gamealgo report preview --pack dev/gamealgo/report-pack.json --json
gamealgo report publish dev/gamealgo/report-pack.json --json    # 覆盖当前看板，先 report pull 备份
```

两条“player_days … user-days”提示是正常的：区间里按天去重的人数相加，叫“人天”。

## game.json：游戏能填的几项

```json
{
  "title": "老街铁匠铺数据看板",
  "effectiveVersion": "1.0.8",
  "effectiveVersions": { "level_start": "1.0.2" },
  "play": {
    "title": "打铁与地牢",
    "modes": ["亲手打铁", "回炉精锻", "地牢"],
    "desc": { "level_id": "打铁为器型，地牢为地图_阶", "result": "通关 win、全灭 lose、撤退 quit" }
  },
  "milestones": {
    "new_user": { "title": "新用户前期流程", "windowDays": 14, "points": ["进店", "首次开炉"] },
    "global": { "title": "铺子成长", "windowDays": 119, "points": ["铺子Lv2", "铺子Lv3"] }
  },
  "extraFields": [
    { "name": "grade", "type": "string", "desc": "打铁评级 S/A/B/C", "chart": "bar", "title": "评级分布" }
  ],
  "retiredBefore": "1.0.8",
  "retiredResults": ["draw"],
  "retired": { "level_end": { "score": { "type": "number", "desc": "总评分" } } }
}
```

| 键 | 说明 |
|---|---|
| `title` | 看板标题 |
| `effectiveVersion` | 词典里新事件从哪个版本起报；`effectiveVersions` 给已经登记过的事件保留原来的版本号 |
| `play.title` / `play.modes` / `play.desc` | 玩法页那一组的标题；`mode` 的取值；词典里 `level_start`、`level_end`、`level_id`、`level_no`、`level_name`、`mode`、`result` 的说明 |
| `milestones` | 里程碑节点名，要和代码里 `TelemetryKit.Milestone` 报的一字不差；每类最多 100 个 |
| `extraFields` | 最多 3 个，只上 `level_end`。`type` 是 string / number / boolean，`chart` 是 bar / pie（按取值数次数）。Lua 里 `TelemetryKit.Init` 的 `extraFields` 要声明同样的名字和类型 |
| `retired` / `retiredResults` / `retiredBefore` | 换成固定上报之前后台词典里已有、现在不报的字段和 result 取值。照写一遍，生成时改成选填并注明，免得老包的数据被当成缺必填。整个不再报的自定义事件用 `gamealgo events deprecate` |
