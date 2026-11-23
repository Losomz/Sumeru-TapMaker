#!/usr/bin/env node
// 按固定模板生成项目的数据后台看板和事件词典。
//   用法（项目根目录）：node dev/sumeru/gamealgo/make-pack.js [项目根]
//   读  dev/gamealgo/game.json（游戏能填的那几项，格式见 README.md）
//   写  dev/gamealgo/report-pack.json、dev/gamealgo/events.yaml（生成物，别手改）
//   之后：gamealgo report preview --pack dev/gamealgo/report-pack.json --json 过了，再 report publish；
//         gamealgo events apply dev/gamealgo/events.yaml（没有试运行，直接提交）
"use strict";
const fs = require("fs");
const path = require("path");

const here = __dirname;
const root = path.resolve(process.argv[2] || process.cwd());
const outDir = path.join(root, "dev", "gamealgo");
const gamePath = path.join(outDir, "game.json");

function fail(msg) {
  console.error("[make-pack] " + msg);
  process.exit(1);
}
function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch (e) {
    fail("读不了 " + p + "：" + e.message);
  }
}

const game = readJson(gamePath);
const pack = readJson(path.join(here, "report-pack.template.json"));
const dict = readJson(path.join(here, "events.template.json"));

// ---------------------------------------------------------------- 校验 game.json
const FIXED = ["level_attempt_id", "level_id", "mode", "level_no", "level_name", "result"];
const TYPES = ["string", "number", "boolean"];
const CHARTS = ["bar", "pie"];
const MAX_EXTRA = 3; // 和 TelemetryKit.MAX_EXTRA 一致

if (typeof game.title !== "string" || !game.title) fail("game.json 缺 title（看板标题）");
if (typeof game.effectiveVersion !== "string") fail("game.json 缺 effectiveVersion（新事件从哪个版本起报，如 1.0.8）");
const play = game.play || {};
if (typeof play.title !== "string" || !play.title) fail("game.json 缺 play.title（玩法页那一组的标题）");

const extras = game.extraFields || [];
if (!Array.isArray(extras)) fail("extraFields 要是数组");
if (extras.length > MAX_EXTRA) fail(`extraFields 最多 ${MAX_EXTRA} 个，现在 ${extras.length} 个`);
const seen = new Set();
for (const f of extras) {
  if (!/^[a-z][a-z0-9_]*$/.test(f.name || "")) fail("额外字段名只能小写字母、数字、下划线：" + f.name);
  if (FIXED.includes(f.name)) fail("额外字段不能和固定字段重名：" + f.name);
  if (seen.has(f.name)) fail("额外字段重复：" + f.name);
  seen.add(f.name);
  if (!TYPES.includes(f.type)) fail(`额外字段 ${f.name} 的 type 只能是 ${TYPES.join(" / ")}`);
  if (!CHARTS.includes(f.chart)) fail(`额外字段 ${f.name} 的 chart 只能是 ${CHARTS.join(" / ")}`);
  if (typeof f.title !== "string" || !f.title) fail(`额外字段 ${f.name} 缺 title（图的标题）`);
  if (typeof f.desc !== "string" || !f.desc) fail(`额外字段 ${f.name} 缺 desc（词典里的说明）`);
}

const ms = game.milestones || {};
for (const kind of Object.keys(ms)) {
  if (kind !== "new_user" && kind !== "global") fail("里程碑只有 new_user / global：" + kind);
  const m = ms[kind];
  if (typeof m.title !== "string" || !m.title) fail(`milestones.${kind} 缺 title`);
  if (!Array.isArray(m.points) || m.points.length === 0) fail(`milestones.${kind}.points 要列出节点名`);
  if (m.points.length > 100) fail(`milestones.${kind} 最多 100 个节点，现在 ${m.points.length} 个`);
  if (new Set(m.points).size !== m.points.length) fail(`milestones.${kind}.points 有重名`);
}

// ---------------------------------------------------------------- 看板
pack.title = game.title;
pack.milestones = ["new_user", "global"]
  .filter((k) => ms[k])
  .map((k) => ({
    type: k,
    title: ms[k].title,
    windowDays: ms[k].windowDays || (k === "new_user" ? 14 : 119),
    entryMode: "cohortUsers",
    points: ms[k].points,
  }));
const playGroup = pack.groups.find((g) => g.id === "play");
playGroup.title = play.title;
for (const f of extras) {
  pack.events.level_end.fields[f.name] = { path: "$." + f.name, type: f.type };
  const ds = "extra_" + f.name + "_daily";
  pack.datasets[ds] = {
    type: "event",
    fromEvent: "level_end",
    filter: { field: f.name, op: "is_not_null" },
    groupBy: ["dt", "mode", f.name],
    metrics: { ends: { agg: "count" } },
  };
  const view = {
    id: "extra_" + f.name,
    title: f.title,
    type: f.chart,
    data: { dataset: ds, groupBy: [f.name], metrics: { ends: { agg: "sum", field: "ends", title: "次数" } } },
  };
  if (f.chart === "bar") Object.assign(view, { x: f.name, y: "ends", orderBy: [{ field: f.name, direction: "asc" }] });
  else Object.assign(view, { label: f.name, value: "ends" });
  playGroup.views.push(view);
}

// ---------------------------------------------------------------- 事件词典
const events = dict.events;
const desc = play.desc || {};
for (const ev of ["level_start", "level_end"]) {
  const e = events[ev];
  if (desc[ev]) e.desc = desc[ev];
  for (const k of ["level_id", "level_no", "level_name", "mode", "result"]) {
    if (desc[k] && e.fields[k]) e.fields[k].desc = ev === "level_start" || k === "result" ? desc[k] : "与对应 level_start 一致：" + desc[k];
  }
  if (Array.isArray(play.modes) && play.modes.length) e.fields.mode.enumValues = play.modes;
}
// 老版本报过、现在不报的 result 取值（比如 draw），留在枚举里免得老包的数据被判不合法
const oldResults = game.retiredResults || [];
if (oldResults.length) {
  const r = events.level_end.fields.result;
  r.enumValues = r.enumValues.concat(oldResults.filter((v) => !r.enumValues.includes(v)));
  r.desc += `（${oldResults.join("、")} 是 ${game.retiredBefore || "老版本"} 以前的老包才报的）`;
}
for (const f of extras) events.level_end.fields[f.name] = { type: f.type, desc: f.desc };
// 老字段：后台词典里已经有、新版不再报的，改成选填并注明（不然后台照旧按必填查）
const retired = game.retired || {};
for (const ev of Object.keys(retired)) {
  if (!events[ev]) fail(`retired 里的 ${ev} 不是固定事件；不再报的整个事件用 gamealgo events deprecate`);
  for (const [name, f] of Object.entries(retired[ev])) {
    if (events[ev].fields && events[ev].fields[name]) fail(`retired 里的 ${ev}.${name} 是固定字段`);
    events[ev].fields = events[ev].fields || {};
    events[ev].fields[name] = { type: f.type, desc: `（${game.retiredBefore || "老版本"} 以前才报，现在不报）${f.desc || ""}` };
  }
}
const versions = game.effectiveVersions || {};

// 最小 YAML：键照写，字符串一律 JSON 引号（YAML 双引号字符串兼容 JSON）
const q = (v) => JSON.stringify(v);
const lines = [
  "# GameAlgo 事件词典（gamealgo events apply 的源文件）",
  "# 由 dev/sumeru/gamealgo/make-pack.js 按 dev/gamealgo/game.json 生成，别手改；事件名和字段是框架定死的，见 dev/sumeru/gamealgo/README.md",
  "# 自定义事件经 SDK TrackEvent 上报，事件名自动加下划线前缀（boot_ready → _boot_ready）",
  "events:",
];
for (const [name, e] of Object.entries(events)) {
  lines.push(`  ${name}:`);
  lines.push(`    desc: ${q(e.desc)}`);
  lines.push(`    effectiveVersion: ${q(versions[name] || game.effectiveVersion)}`);
  const fields = Object.entries(e.fields || {});
  if (!fields.length) continue;
  lines.push("    fields:");
  for (const [fname, f] of fields) {
    lines.push(`      ${fname}:`);
    lines.push(`        type: ${f.type}`);
    lines.push(`        desc: ${q(f.desc)}`);
    lines.push(`        required: ${f.required === true}`);
    if (f.enumValues) lines.push(`        enumValues: [${f.enumValues.map(q).join(", ")}]`);
  }
}

fs.writeFileSync(path.join(outDir, "report-pack.json"), JSON.stringify(pack, null, 2) + "\n");
fs.writeFileSync(path.join(outDir, "events.yaml"), lines.join("\n") + "\n");
console.log(`[make-pack] 写好 ${path.relative(root, outDir)}/report-pack.json、events.yaml：` +
  `里程碑 ${pack.milestones.map((m) => m.type + " " + m.points.length).join("、") || "无"}，额外字段 ${extras.map((f) => f.name).join("、") || "无"}`);
