"use strict";
// 发布流水线：发包、更新上架、版本号，每一步一条固定命令，顺序和选项写死在这里，不再临场决定。
// 用法：node dev/sumeru/release/release.js <命令> [--version 1.0.N]，命令和对应的清单步骤见同目录 README.md。
// 每次发布的进度记在 docs/更新日志/<版本>/发布记录.json：中途断了，重跑同一条命令会跳过做完的部分接着做。
// 只用各工具自己存好的登录（taptap-cli、Maker），不读也不打印任何密钥；输出里的地址和令牌一律打码。
const fs = require("fs");
const path = require("path");
const os = require("os");
const cp = require("child_process");
const crypto = require("crypto");
const md2draft = require("../publish/md2draft.js");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const TMP = path.join(ROOT, ".tmp", "release");
const LOGS = path.join(ROOT, "docs", "更新日志");
const CHECKLIST = path.join(__dirname, "发布清单模板.md");
const LOG_TEMPLATE = path.join(__dirname, "..", "publish", "templates", "更新日志", "模板.md");

// ---------------------------------------------------------------- 输出

let fails = 0;
let pendings = 0;
const say = (tag, name, msg) => console.log(`  [${tag}] ${name}：${msg}`);
const ok = (name, msg) => say("过", name, msg);
const bad = (name, msg) => { fails++; say("不过", name, msg); };
const wait = (name, msg) => { pendings++; say("等待", name, msg); };
const info = (name, msg) => say("提示", name, msg);
const head = (s) => console.log(`\n== ${s}`);
class Stop extends Error {}
const stop = (msg) => { throw new Stop(msg); };

// 打码：git 地址里的令牌、Bearer、GameAlgo 密钥。
const redact = (s) => String(s || "")
    .replace(/:\/\/[^@\s/]*@/g, "://***@")
    .replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, "$1***")
    .replace(/(ga_(?:live|setup|admin|org)_)[A-Za-z0-9]+/g, "$1***");

const now = () => Date.now();
// 时间一律按北京时间显示（TapTap、Maker 都是），不跟这台电脑的系统时区走。
const fmt = (ms) => new Date(ms).toLocaleString("sv-SE", { timeZone: "Asia/Shanghai", hour12: false }).slice(0, 16);
const today = () => fmt(now()).slice(0, 10);
const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");

// ---------------------------------------------------------------- 文件

const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8").replace(/^﻿/, ""));
const readJsonMaybe = (p) => (fs.existsSync(p) ? readJson(p) : null);
const writeJson = (p, o) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n"); };
const rel = (p) => path.relative(ROOT, p).replace(/\\/g, "/");

// ---------------------------------------------------------------- 版本号

const parseV = (v) => String(v).split(".").map(Number);
const cmpVer = (a, b) => {
    const x = parseV(a), y = parseV(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) { const d = (x[i] || 0) - (y[i] || 0); if (d) return d; }
    return 0;
};
// Maker 版本号跟着包走（2026-11-22 对过 spark 4–13，第 N 个包都是 1.0.(N−1)）：每出一个包用掉一个号；
// 号只在要出新包时往前走——云端这个号已经出过包，下一次构建（或发布页出包）先 +1；还没出过包（只构建、没在发布页出包）就不涨。
// 所以本次 = 下一个包的号（nextVersion），不能拿“云端号 +1”算：1.0.13 那次云端 1.0.12 只构建过、没出过包，
// 构建没涨号，包出来还是 1.0.12，第 10 步一直等 1.0.13。被拒后重建：被拒那个包用掉了号，重建必是下一号，要跑 renumber。
const addLast = (v, n) => { const p = parseV(v); p[p.length - 1] += n; return p.join("."); };
const bump = (v) => addLast(v, 1);
// 公告里只写后两段：1.0.8 → v0.8。
const noticeOf = (v) => "v" + parseV(v).slice(1).join(".");

// ---------------------------------------------------------------- 外部命令

function run(cmd, args, opts = {}) {
    const r = cp.spawnSync(cmd, args, {
        cwd: opts.cwd || ROOT, encoding: "utf8", timeout: opts.timeout || 180000,
        maxBuffer: 64 << 20, windowsHide: true,
    });
    return { code: r.status, out: r.stdout || "", err: r.stderr || "", error: r.error };
}

// npm 全局命令在 Windows 上是 .cmd 外壳，直接找到里面的 js 用 node 跑，参数不经过 cmd 转义。
function npmScript(name) {
    for (const dir of (process.env.PATH || "").split(path.delimiter)) {
        if (!dir) continue;
        const shim = path.join(dir, name + ".cmd");
        if (!fs.existsSync(shim)) continue;
        const m = fs.readFileSync(shim, "utf8").match(/%dp0%\\([^"]+\.js)/);
        if (m && fs.existsSync(path.join(dir, m[1]))) return path.join(dir, m[1]);
    }
    for (const dir of (process.env.PATH || "").split(path.delimiter)) {
        const bin = path.join(dir, name);
        if (dir && fs.existsSync(bin) && !fs.existsSync(bin + ".cmd")) return bin;
    }
    return null;
}

let tapJs = null;
let reqN = 0;
// 调 taptap-cli，返回 data.result。读操作网络出错重试 3 次；写操作只跑一次，带固定的防重复键，重跑时同一个键不会重复写。
function tap(service, op, data, o = {}) {
    tapJs = tapJs || npmScript("taptap-cli") || stop("找不到 taptap-cli：先 npm i -g @taptap/cli 并登录");
    const args = [tapJs, service, op];
    if (o.positional) args.push(o.positional);
    if (o.appOnly) args.push("--app-id", String(cfg.appId));
    else args.push("--dev-id", String(cfg.devId), "--app-id", String(cfg.appId));
    if (data !== undefined) {
        const f = `req-${process.pid}-${++reqN}.json`;
        fs.writeFileSync(path.join(TMP, f), JSON.stringify(data));
        args.push("--data", "@" + f);   // --data @文件 只认当前目录，所以在 .tmp/release 里跑
    }
    if (o.key) args.push("--idempotency-key", o.key);
    if (o.yes) args.push("--yes");
    if (o.dryRun) args.push("--dry-run");
    args.push("--json");
    let last = "";
    for (let i = 0; i < (o.write ? 1 : 3); i++) {
        const r = run(process.execPath, args, { cwd: TMP, timeout: 120000 });
        let j = null;
        try { j = JSON.parse(r.out); } catch (e) { /* 不是 JSON */ }
        if (j && j.ok) return j.data && j.data.result !== undefined ? j.data.result : j.data;
        last = j && j.error ? `${j.error.code || ""} ${j.error.message || JSON.stringify(j.error)}` : (r.err || r.out || String(r.error)).slice(0, 400);
    }
    stop(`taptap-cli ${service} ${op} 失败：${redact(last).trim()}`);
}

// Maker 命令行：用本机装的最新 mcp-runtime，可用环境变量 SUMERU_MAKER_JS 指定。
function makerJs() {
    if (process.env.SUMERU_MAKER_JS) return process.env.SUMERU_MAKER_JS;
    const base = path.join(os.homedir(), ".taptap-maker", "mcp-runtime");
    const vers = fs.existsSync(base) ? fs.readdirSync(base).filter((v) => fs.existsSync(path.join(base, v, "dist", "maker.js"))).sort(cmpVer) : [];
    if (!vers.length) stop("找不到 Maker 命令行（~/.taptap-maker/mcp-runtime/*/dist/maker.js），先在 AI 客户端里装好 Maker MCP");
    return path.join(base, vers[vers.length - 1], "dist", "maker.js");
}
function maker(args) {
    const r = run(process.execPath, [makerJs(), ...args, "--target-dir", ROOT, "--json"]);
    try { return JSON.parse(r.out); } catch (e) { stop(`Maker ${args.join(" ")} 没返回结果：${redact(r.err || r.out).slice(0, 400)}`); }
}

function git(args, o = {}) {
    const r = run("git", ["-C", ROOT, ...args]);
    if (r.code !== 0 && !o.soft) stop(`git ${args[0]} 失败：${redact(r.err || r.out).trim()}`);
    return r.code === 0 ? r.out.trim() : null;
}
const headCommit = () => git(["rev-parse", "--short", "HEAD"]);

// ---------------------------------------------------------------- 项目配置

const projectJson = () => readJson(path.join(ROOT, ".project", "project.json"));
const DEFAULTS = {
    appVersion: [],              // [{file, match}]：match 是正则，第一个括号是版本号
    test: null,                  // {entry, script, frames, timeout, must:[…]}
    post: { group: "0", pinDays: 30, mustInclude: ["交流群"] },
    // 审核敏感词：简介里有就不过；游戏文字里有只提示，删不删由开发者定。
    // 1.0.10 简介里一句“黄姨彩票站刮一张”被拒，换成“喜刮刮”也被拒。
    review: {
        words: ["彩票", "博彩", "赌博", "赌场", "下注", "刮刮乐", "老虎机", "六合彩"],
        descMax: 300,   // 简介超过这么多字就提示精简
        scan: ["scripts", "assets/ui"],
        skip: ["scripts/tests", "scripts/dev", "scripts/sumeru", "scripts/sdk"],
    },
};
let cfg = null;
function loadConfig() {
    const pjPath = path.join(ROOT, ".project", "project.json");
    if (!fs.existsSync(pjPath)) stop("找不到 .project/project.json：这不是绑定过的 Maker 游戏项目");
    const tp = projectJson().taptap_publish || {};
    const own = readJsonMaybe(path.join(ROOT, "dev", "release.json"));
    if (!own) stop("缺少 dev/release.json（版本号写在哪、怎么跑测试），格式见 dev/sumeru/release/README.md");
    cfg = {
        ...DEFAULTS, ...own, post: { ...DEFAULTS.post, ...(own.post || {}) }, review: { ...DEFAULTS.review, ...(own.review || {}) },
        game: tp.title || path.basename(ROOT), devId: tp.developer_id, appId: tp.app_id, platforms: tp.app_platforms,
        slug: path.basename(ROOT),
    };
    if (!cfg.devId || !cfg.appId) stop("project.json 里没有 TapTap 的 developer_id / app_id：先在 Maker 发布页绑定 TapTap 游戏");
    fs.mkdirSync(TMP, { recursive: true });
}

// ---------------------------------------------------------------- 发布记录

const recPath = (v) => path.join(LOGS, v, "发布记录.json");
// 记录是几条命令共用的：test、check 一跑几分钟，这期间别的命令（比如 approve）可能已经改过它。
// 所以写回时只写这条命令自己改过的字段，其余照磁盘上最新的，免得把别人刚写的冲掉（1.0.9 时 test 冲掉过 approve）。
const BASE = Symbol("读进来时的样子");
const snap = (o) => JSON.parse(JSON.stringify(o));
function track(rec) { Object.defineProperty(rec, BASE, { value: snap(rec), writable: true }); return rec; }
function saveRec(rec) {
    rec.updatedAt = fmt(now());
    const base = rec[BASE] || {};
    const out = { ...(readJsonMaybe(recPath(rec.version)) || {}) };
    for (const k of new Set([...Object.keys(base), ...Object.keys(rec)])) {
        if (JSON.stringify(rec[k]) === JSON.stringify(base[k])) continue;   // 这条命令没动过：用磁盘上的
        if (rec[k] === undefined) delete out[k]; else out[k] = rec[k];
    }
    writeJson(recPath(rec.version), out);
    for (const k of Object.keys(rec)) if (!(k in out)) delete rec[k];
    Object.assign(rec, out);
    rec[BASE] = snap(out);
}
function allRecs() {
    if (!fs.existsSync(LOGS)) return [];
    return fs.readdirSync(LOGS).filter((d) => /^\d+(\.\d+)+$/.test(d) && fs.existsSync(recPath(d))).sort(cmpVer).map((d) => track(readJson(recPath(d))));
}
function loadRec(argv) {
    const v = argv.version;
    if (v) { if (!fs.existsSync(recPath(v))) stop(`没有 ${v} 的发布记录，先跑 new`); return track(readJson(recPath(v))); }
    const recs = allRecs();
    if (!recs.length) stop("还没有发布记录，先跑 new");
    return recs[recs.length - 1];
}
// 下一步该做什么，按清单顺序。
function nextStep(rec) {
    if (rec.verify && (!rec.post || !rec.post.draftId)) return `已上线，更新公告还没出：写 docs/更新日志/${rec.version}/日志.md → draft → 开发者确认后 approve → finish`;
    if (!rec.post || !rec.post.draftId) return `第 2 步：写好 docs/更新日志/${rec.version}/日志.md，跑 draft（不另写公告、沿用已发的就跑 reuse --from 1.0.N）`;
    if (!rec.approve || rec.approve.hash !== rec.post.hash) return `第 3 步：把公告预览 ${rec.post.previewUrl} 给开发者看，点头后跑 approve`;
    const rj = rejections(rec).slice(-1)[0];
    if (!rec.verify && rj && !rj.handled) return `${rj.tapVersion} 被拒（${rj.reason}）：只改资料就改好本地 project.json 跑 resubmit；要改代码就改完跑 renumber，再 prepare → 构建`;
    if (!rec.check || !rec.check.ok) return "第 4–6 步：跑 prepare（写版本号、全量测试、发布前检查）";
    if (!rec.verify) return "第 8–9 步：Maker 构建（maker_build_current_directory），构建前说“先别开发布页”；构建完请开发者把发布页刷新后点「保持状态并更新版本」，再跑 finish";
    if (!rec.post.momentId || !rec.pin || !rec.pin.contentId || !rec.done) return "第 11–13 步：跑 finish";
    return "这一版发完了";
}

// ---------------------------------------------------------------- 各项读取

// 代码里写的 appVersion（数据后台上报用），dev/release.json 的 appVersion 列出写在哪。
function appVersions() {
    return cfg.appVersion.map((e) => {
        const f = path.join(ROOT, e.file);
        if (!fs.existsSync(f)) return { file: e.file, value: null, why: "文件不存在" };
        const m = fs.readFileSync(f, "utf8").match(new RegExp(e.match));
        return { file: e.file, value: m ? m[1] : null, why: m ? "" : "没找到版本号" };
    });
}

// TapTap 版本列表（新的在前）和 Maker 包（spark，新的在前）。
const tapVersions = () => (tap("app", "list-versions", { page: 1, page_size: 5 }).list || []);
const sparks = () => (tap("package-management", "list-spark-versions").list || []).sort((a, b) => Number(b.version_code) - Number(a.version_code));

// 包号锚点 {spark, version, from}：哪个包是哪个号。先找最近一次核对上线记下的（第 10 步记 verify.makerVersion），
// 没有就用测试二维码（project.json 的 test_qrcode：map_version 是包号，game_version 是那个包的号）。
function versionAnchor() {
    const recs = allRecs().filter((r) => r.verify && r.verify.spark && r.verify.makerVersion).sort((a, b) => b.verify.spark - a.verify.spark);
    if (recs[0]) return { spark: Number(recs[0].verify.spark), version: recs[0].verify.makerVersion, from: `${recs[0].version} 上线时 spark ${recs[0].verify.spark}` };
    const q = projectJson().test_qrcode || {};
    if (q.map_version && q.game_version) return { spark: Number(q.map_version), version: q.game_version, from: `测试二维码 spark ${q.map_version}` };
    return null;
}

// 本次定号 {version, maker, why}：maker 是下一个包的 Maker 号 = 锚点号 + 隔了几个包，只能是云端号（还没出过包）
// 或云端号 +1（出过了），别的就是锚点不对，version 给 null、why 说清楚，别硬发。
// version 是本次的号（目录、公告、appVersion），平常就等于 maker；比已发完的还小或撞上（1.0.13 实际出的是 Maker 1.0.12 包，
// 下一个包又是 1.0.13），就接着已发完的往后排，第 10 步拿 maker 核对。sp 是 sparks() 的结果。
function nextVersion(cloudV, sp) {
    const latest = sp && sp[0] ? Number(sp[0].version_code) : 0;
    const a = versionAnchor();
    let maker, why;
    if (!a) { maker = bump(cloudV); why = `没有包号锚点，按云端 ${cloudV} +1 猜（第 10 步核对上线后就有了）`; }
    else {
        maker = addLast(a.version, latest + 1 - a.spark);
        if (maker !== cloudV && maker !== bump(cloudV)) return { version: null, maker, why: `按 ${a.from} 是 ${a.version} 推，下一个包该是 ${maker}，可云端是 ${cloudV}，对不上：先跑 status，查清楚再定号` };
        why = maker === cloudV ? `云端 ${cloudV} 还没出过包，这次构建不涨号` : `云端 ${cloudV} 已经出过包（spark ${latest}），这次构建 +1`;
    }
    const done = allRecs().filter((r) => r.verify).map((r) => r.version).sort(cmpVer).pop();
    if (done && cmpVer(maker, done) <= 0) return { version: bump(done), maker, why: `${why}，包号是 ${maker}；${done} 已经发过，本次记 ${bump(done)}` };
    return { version: maker, maker, why };
}
// 第 10 步核对用：这次的包该是哪个 Maker 号（记录里没记 maker 的老记录，就是本次号）。
const makerOf = (rec) => rec.maker || rec.version;

// 云端工作区状态：{clean, files, head}。
function cloudStatus() {
    const st = maker(["git", "cloud-status"]);
    if (!st.ok) stop(`读不到 Maker 云端状态：${redact(JSON.stringify(st.error || st)).slice(0, 300)}`);
    return st;
}

// 商店简介：本地 project.json 里的，和 TapTap 上现在的。
// 发布页点更新时，交给 TapTap 的是它表单里的简介。开着的旧页面会把旧简介写回去（1.0.11 因此第二次被拒），所以第 10 步要读回核对。
const localDesc = () => (projectJson().taptap_publish || {}).description || "";
const tapDesc = () => (((tap("app", "get-app-module", { module_id: "basic-info" }).fields || {}).description) || {}).current_value || "";
const reviewHits = (text) => cfg.review.words.filter((w) => String(text || "").includes(w));
const chars = (s) => [...String(s || "")].length;

// 游戏文字里的审核敏感词：扫 review.scan 下的 .lua（去掉注释）和 .json，跳过 review.skip。返回 [{file, line, word}]。
function scanGameWords() {
    const hits = [];
    const skip = (p) => cfg.review.skip.some((s) => p === s || p.startsWith(s + "/"));
    // Lua 一行去掉注释：引号外的 -- 之后都不要。
    const code = (line) => {
        let q = null;
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (q) { if (c === "\\") i++; else if (c === q) q = null; }
            else if (c === '"' || c === "'") q = c;
            else if (c === "-" && line[i + 1] === "-") return line.slice(0, i);
        }
        return line;
    };
    const walk = (dir) => {
        const abs = path.join(ROOT, dir);
        if (!fs.existsSync(abs) || skip(dir)) return;
        for (const e of fs.readdirSync(abs, { withFileTypes: true })) {
            const p = `${dir}/${e.name}`;
            if (e.isDirectory()) { walk(p); continue; }
            if (skip(p) || !/\.(lua|json)$/.test(e.name)) continue;
            fs.readFileSync(path.join(ROOT, p), "utf8").split(/\r?\n/).forEach((l, i) => {
                for (const w of reviewHits(p.endsWith(".lua") ? code(l) : l)) hits.push({ file: p, line: i + 1, word: w });
            });
        }
    };
    for (const d of cfg.review.scan) walk(d);
    return hits;
}

// 被拒的那次：TapTap 版本最后一条 review_rejected 的时间和原因（重提的防重复键靠这个时间区分每次被拒）。
function lastRejection(tapVersion) {
    const logs = (tap("app", "get-app-version", { version: tapVersion }).logs || []).filter((l) => l.event === "review_rejected");
    const l = logs[logs.length - 1];
    return l ? { at: Number(l.updated_time), reason: l.reason || "" } : null;
}
// 1.0.11 之前手写的记录里 rejected 是单个对象，统一当数组读。
const rejections = (rec) => [].concat(rec.rejected || []);
// 被拒记进发布记录（同一次被拒只记一条），handled 写的是后来怎么处理的：resubmit / renumber。
function noteRejection(rec, v, spark) {
    const r = lastRejection(v.version) || { at: 0, reason: v.status_reason || "" };
    rec.rejected = rejections(rec);
    if (!rec.rejected.find((x) => x.tapVersion === v.version && x.rejectedAt === r.at)) {
        rec.rejected.push({ version: rec.version, spark, tapVersion: v.version, reason: r.reason || v.status_reason || "", rejectedAt: r.at, at: fmt(now()) });
        saveRec(rec);
    }
    return rec.rejected[rec.rejected.length - 1];
}
function markHandled(rec, how) {
    const rj = rejections(rec).slice(-1)[0];
    if (rj && !rj.handled) rj.handled = how;
}

// 公开的游戏详情页上，主按钮写的是什么：能玩是“打开 APP 试玩”之类，没上架是“关注 / 预约”。
async function storeButton() {
    try {
        const res = await fetch(`https://www.taptap.cn/app/${cfg.appId}`, { headers: { "User-Agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(20000) });
        const html = await res.text();
        const m = html.match(/miniappbuttontext="([^"]*)"/) || html.match(/aside-action-btn__label"[^>]*>([^<]+)</);
        return m ? m[1].trim() : "";
    } catch (e) { return null; }
}
// 详情页上的简介对不对：本地简介每行取开头 14 个字去详情页里找（整行可能被转义），返回找不到的那几行开头；页面打不开返回 null。
async function storeDescMissing(desc) {
    try {
        const res = await fetch(`https://www.taptap.cn/app/${cfg.appId}`, { headers: { "User-Agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(20000) });
        const html = await res.text();
        return String(desc).split("\n").map((l) => [...l.trim()].slice(0, 14).join("")).filter((l) => l && !html.includes(l));
    } catch (e) { return null; }
}
const playable = (label) => /试玩|开始|下载|玩/.test(label || "") && !/预约|关注/.test(label || "");

// 公告稿：读 日志.md，找出要上传的图片，查占位符和标题。
function readNotice(rec) {
    const file = path.join(LOGS, rec.version, "日志.md");
    if (!fs.existsSync(file)) return { file, problems: [`没有 ${rel(file)}`] };
    const text = fs.readFileSync(file, "utf8");
    const body = text.split(/^<!--/m)[0];
    const problems = [];
    const tm = body.match(/^# (.+)$/m);
    const want = `【更新公告】${rec.notice} `;
    if (!tm) problems.push("没有一级标题");
    else if (!tm[1].startsWith(want)) problems.push(`标题要以“${want}”开头，现在是“${tm[1]}”`);
    const holes = body.match(/<[^<>\n!][^<>\n]*>/g);
    if (holes) problems.push(`还有没填的占位：${holes.slice(0, 3).join(" ")}`);
    for (const s of cfg.post.mustInclude) if (!body.includes(s)) problems.push(`正文里要有“${s}”`);
    const images = [...body.matchAll(/^!\[[^\]]*\]\(([^)]+)\)/gm)].map((m) => m[1]);
    return { file, text, title: tm ? tm[1] : "", images, problems };
}
// 按稿子和已上传的图片拼出草稿文档；返回 {doc, hash, conv}。
function noticeDoc(rec, n) {
    const map = {};
    for (const [src, img] of Object.entries(rec.images || {})) map[src] = img;
    const conv = md2draft.convert(n.text, map);
    const doc = md2draft.toDocument(conv, cfg.appId, { group: cfg.post.group });
    return { doc, conv, hash: sha(JSON.stringify(doc)) };
}

// ---------------------------------------------------------------- 步骤

// 同步云端：发布页写在云端、没提交的 project.json 先提交掉（只认这一个文件，别的改动停下来报），再把云端提交合并到本地。
function syncCloud() {
    const st = cloudStatus();
    if (!st.clean) {
        const files = (st.files || []).map((f) => f.path);
        const other = files.filter((f) => f !== ".project/project.json");
        if (other.length) stop(`云端工作区有没提交的改动，不只是 project.json：${files.join("、")}。先查清是谁改的再处理`);
        const c = maker(["git", "cloud-commit", "--message", "chore: 提交 Maker 发布页写的 project.json", "--expected-head", st.head, ".project/project.json"]);
        if (!c.ok) stop(`提交云端 project.json 失败：${redact(JSON.stringify(c.error || c)).slice(0, 300)}`);
        ok("云端", "发布页写的 project.json 已提交");
    } else ok("云端", "没有没提交的改动");
    git(["fetch", "-q", "origin"]);
    const behind = Number(git(["rev-list", "--count", "HEAD..origin/main"]));
    const ahead = Number(git(["rev-list", "--count", "origin/main..HEAD"]));
    if (behind) {
        const r = run("git", ["-C", ROOT, "merge", ahead ? "--no-edit" : "--ff-only", "-q", "origin/main"]);
        if (r.code !== 0) stop(`合并云端提交失败（本地有冲突的改动？）：${redact(r.err || r.out).trim()}`);
        ok("本地", `合并了云端 ${behind} 个提交`);
    } else ok("本地", "和云端一致" + (ahead ? `，本地多 ${ahead} 个提交还没推（构建时一起推）` : ""));
}

async function cmdStatus(argv) {
    head(`${cfg.game} · 版本一览`);
    const pj = projectJson();
    const st = cloudStatus();
    git(["fetch", "-q", "origin"]);
    const originPj = JSON.parse(git(["show", "origin/main:.project/project.json"]).replace(/^﻿/, ""));
    let cloudV = originPj.version;
    const dirty = (st.files || []).map((f) => f.path);
    if (dirty.includes(".project/project.json")) {
        const d = maker(["git", "cloud-diff", "--path", ".project/project.json"]);
        const m = JSON.stringify(d).match(/\\n\+\s*\\"version\\":\s*\\"([0-9.]+)\\"/);
        if (m) cloudV = m[1];
    }
    console.log(`  Maker 云端      ${cloudV}${dirty.length ? `（云端有没提交的改动：${dirty.join("、")}）` : ""}`);
    console.log(`  本地            ${pj.version}（git ${headCommit()}${pj.version === cloudV ? "" : "，和云端不一样，跑 sync"}）`);
    for (const a of appVersions()) console.log(`  代码 appVersion ${a.value || "？"}（${a.file}${a.why ? "，" + a.why : ""}）`);
    const vs = tapVersions();
    for (const v of vs.slice(0, 2)) console.log(`  TapTap 版本     ${v.version} ${v.status_label}（${fmt(v.created_time * 1000)} 建）`);
    const sp = sparks();
    if (sp[0]) console.log(`  最新的包        spark ${sp[0].version_code}（${fmt(sp[0].updated_at * 1000)}）`);
    const btn = await storeButton();
    console.log(`  详情页按钮      ${btn === null ? "读不到" : btn || "没找到"}${btn && !playable(btn) ? "（玩家现在玩不了！）" : ""}`);
    const next = nextVersion(cloudV, sp);
    if (next.version) console.log(`  下一个版本      ${next.version}（公告 ${noticeOf(next.version)}；${next.why}）`);
    else console.log(`  下一个版本      定不了：${next.why}`);
    const recs = allRecs();
    const open = recs.filter((r) => !r.done);
    if (open.length) for (const r of open) console.log(`  进行中的发布    ${r.version}：${nextStep(r)}`);
    else console.log(`  进行中的发布    没有${recs.length ? `（上一次 ${recs[recs.length - 1].version}）` : ""}`);
}

// 公告稿模板：标题补上“v0.N ”，版本、日期填好，其余占位留给写稿时填。
const fillLog = (tpl, notice, date) => tpl.replace(/^# 【更新公告】/m, `# 【更新公告】${notice} `).replace("<x.y.z>", notice).replace("<YYYY-MM-DD>", date);

// 第 1 步：同步云端、定版本号、建本次的目录（发布清单、公告稿、发布记录）。
async function cmdNew() {
    head("第 1 步 定版本号");
    syncCloud();
    const pj = projectJson();
    const sps = sparks();
    const next = nextVersion(pj.version, sps);
    if (!next.version) stop(next.why);
    const v = next.version;
    if (fs.existsSync(recPath(v))) { ok("版本号", `${v} 已经开过了：docs/更新日志/${v}/`); return track(readJson(recPath(v))); }
    for (const r of allRecs()) if (!r.done) info("没收尾", `${r.version} 还没发完（${nextStep(r)}）`);
    const dir = path.join(LOGS, v);
    fs.mkdirSync(dir, { recursive: true });
    const notice = noticeOf(v);
    const fill = (s) => s.split("{游戏名}").join(cfg.game).split("{版本}").join(v).split("{公告}").join(notice);
    const listFile = path.join(dir, "发布清单.md");
    if (!fs.existsSync(listFile)) fs.writeFileSync(listFile, fill(fs.readFileSync(CHECKLIST, "utf8")));
    const logFile = path.join(dir, "日志.md");
    if (!fs.existsSync(logFile)) {
        const own = path.join(LOGS, "模板.md");
        const tpl = fs.readFileSync(fs.existsSync(own) ? own : LOG_TEMPLATE, "utf8");
        fs.writeFileSync(logFile, fillLog(tpl, notice, today()));
    }
    const sp = sps[0];
    const online = tapVersions().find((x) => x.status === "online");
    const rec = {
        game: cfg.game, version: v, maker: next.maker, notice, createdAt: fmt(now()),
        prev: { version: pj.version, spark: sp ? Number(sp.version_code) : 0, tapVersion: online ? online.version : "" },
    };
    saveRec(rec);
    ok("版本号", `本次 ${v}（${next.why}；公告 ${notice}，数据后台 appVersion 也是 ${v}）`);
    ok("目录", `${rel(dir)}/：发布清单.md、日志.md（公告稿，照模板写）、发布记录.json`);
    return rec;
}

// 第 2 步（稿子写完后）：上传配图、在 TapTap 建好公告草稿，把预览链接交给开发者看。稿子改了就重跑，草稿跟着改，确认作废。
async function cmdDraft(argv) {
    const rec = loadRec(argv);
    head(`第 2 步 公告草稿（${rec.version}）`);
    if (rec.post && rec.post.reusedFrom) { ok("草稿", `沿用 ${rec.post.reusedFrom} 的公告，不用建草稿`); return; }
    const n = readNotice(rec);
    if (n.problems.length) { for (const p of n.problems) bad("公告稿", p); stop("公告稿还没写好"); }
    rec.images = rec.images || {};
    for (const src of n.images) {
        const file = path.join(path.dirname(n.file), src);
        if (!fs.existsSync(file)) stop(`稿子里的图片 ${src} 不存在`);
        const h = sha(fs.readFileSync(file));
        if (rec.images[src] && rec.images[src].sha === h) continue;
        const local = `upload-${h.slice(0, 12)}${path.extname(file)}`;   // 上传的文件也要在当前目录里
        fs.copyFileSync(file, path.join(TMP, local));
        const r = tap("community-management", "+upload-image", undefined, { positional: local, yes: true, write: true, key: `${cfg.slug}-${rec.version}-img-${h.slice(0, 12)}` });
        if (!r.url || !r.width || !r.height) stop(`上传 ${src} 没拿到地址和宽高`);
        rec.images[src] = { sha: h, url: r.url, width: r.width, height: r.height };
        saveRec(rec);
        ok("配图", `${src} 已上传（${r.width}×${r.height}）`);
    }
    const { doc, conv, hash } = noticeDoc(rec, n);
    if (conv.skipped) bad("配图", `有 ${conv.skipped} 张图没转进正文`);
    if (rec.post && rec.post.momentId) stop(`公告已经发出去了（${rec.post.url}），发出去的帖子改不了`);
    if (rec.post && rec.post.draftId && rec.post.hash === hash) {
        ok("草稿", `没变，预览：${rec.post.previewUrl}`);
    } else if (rec.post && rec.post.draftId) {
        tap("community-management", "update-community-topic-draft", { draft_id: rec.post.draftId, document: doc }, { yes: true, write: true, key: `${cfg.slug}-${rec.version}-draft-${hash.slice(0, 12)}` });
        rec.post = { ...rec.post, hash, title: conv.title, at: fmt(now()) };
        delete rec.approve;
        saveRec(rec);
        ok("草稿", `已按新稿子改好，之前的确认作废。预览：${rec.post.previewUrl}`);
    } else {
        const r = tap("community-management", "create-community-topic-draft", doc, { yes: true, write: true, key: `${cfg.slug}-${rec.version}-draft` });
        if (!r.draft_id) stop("建草稿没拿到 draft_id");
        rec.post = { draftId: String(r.draft_id), previewUrl: r.preview_url, hash, title: conv.title, at: fmt(now()) };
        delete rec.approve;
        saveRec(rec);
        ok("草稿", `已建好（还没发，玩家看不到）。预览：${rec.post.previewUrl}`);
    }
    info("下一步", "把预览链接给开发者看；开发者说可以发，再跑 approve");
}

// 第 3 步：记下开发者看过预览、点了头。只在开发者明确说“可以发”之后跑。
async function cmdApprove(argv) {
    const rec = loadRec(argv);
    head(`第 3 步 开发者确认（${rec.version}）`);
    if (rec.post && rec.post.reusedFrom) { ok("确认", `沿用 ${rec.post.reusedFrom} 的公告，开发者跑 reuse 时已经定了`); return; }
    if (!rec.post || !rec.post.draftId) stop("还没建公告草稿，先跑 draft");
    const n = readNotice(rec);
    if (n.problems.length || noticeDoc(rec, n).hash !== rec.post.hash) stop("日志.md 在建草稿之后改过：先重跑 draft，把新预览给开发者看");
    rec.approve = { at: fmt(now()), hash: rec.post.hash };
    saveRec(rec);
    ok("确认", `开发者已确认公告预览（${rec.post.title}），上线后第 11 步照这份发`);
}

// 第 2–3 步的另一条路：这一版不另写公告，沿用已发的更新公告（修复版、紧急重发）。开发者说沿用哪一版才跑。
// 不建草稿、不发帖；第 12 步认得出已经挂着的那条，没挂着就重新挂它；版本表这一行链到那条帖子。
async function cmdReuse(argv) {
    const rec = loadRec(argv);
    const from = argv.from || (prevRelease(rec) || {}).version;
    head(`沿用公告（${rec.version}）`);
    if (!from || !fs.existsSync(recPath(from))) stop("沿用哪一版：--from 1.0.N（那一版的更新公告得发过）");
    const src = readJson(recPath(from));
    if (!src.post || !src.post.momentId) stop(`${from} 的更新公告没发过，没法沿用`);
    if (rec.post && rec.post.momentId && !rec.post.reusedFrom) stop(`本次已经发过自己的公告（${rec.post.url}），不用沿用`);
    if (rec.post && rec.post.draftId && !rec.post.reusedFrom) info("草稿", `本次建过的草稿不发了，留在草稿箱：${rec.post.previewUrl}`);
    const origin = src.post.reusedFrom || from;
    rec.post = { ...src.post, reusedFrom: origin };
    if (argv.note) rec.post.note = argv.note;
    rec.approve = { at: fmt(now()), hash: rec.post.hash, reused: true };
    saveRec(rec);
    const file = path.join(LOGS, rec.version, "日志.md");
    const lines = [`# ${rec.version}：沿用 ${origin} 的更新公告`, "",
        `这一版没有单独的公告，沿用 [${origin}](../${origin}/日志.md) 的“${rec.post.title}”：${rec.post.url}`];
    if (rec.post.note) lines.push("", rec.post.note);
    fs.writeFileSync(file, lines.join("\n") + "\n");
    ok("公告", `沿用 ${origin} 的“${rec.post.title}”，不建草稿、不发帖；${rel(file)} 写成了指向它的说明`);
}

// 第 4 步：把数据后台的 appVersion 写成本次版本号，单独提交一下。
function stepVersion(rec) {
    head("第 4 步 写版本号");
    const next = nextVersion(projectJson().version, sparks());
    if (!next.version) stop(next.why);
    if (rec.version !== next.version) stop(`本次该是 ${next.version}（${next.why}），记录里是 ${rec.version}。被拒后重建过就跑 renumber；不是的话先跑 status 看看`);
    if (makerOf(rec) !== next.maker) { rec.maker = next.maker; saveRec(rec); }
    if (!cfg.appVersion.length) { info("appVersion", "dev/release.json 没写 appVersion，跳过"); return; }
    const changed = [];
    for (const e of cfg.appVersion) {
        const f = path.join(ROOT, e.file);
        const s = fs.readFileSync(f, "utf8");
        const m = s.match(new RegExp(e.match));
        if (!m) stop(`${e.file} 里没找到版本号（${e.match}）`);
        if (m[1] === rec.version) { ok("appVersion", `${e.file} 已经是 ${rec.version}`); continue; }
        fs.writeFileSync(f, s.replace(m[0], m[0].replace(m[1], rec.version)));
        changed.push(e.file);
        ok("appVersion", `${e.file}：${m[1]} → ${rec.version}`);
    }
    if (changed.length) {
        git(["add", "--", ...changed]);
        git(["commit", "-q", "-m", `🔖 chore(release): appVersion ${rec.version}`, "--", ...changed]);
        ok("提交", `${headCommit()}（只提交了版本号）`);
    }
}

// Maker 装好的本机运行时。
function runtimeExe() {
    const base = path.join(os.homedir(), ".taptap-maker", "runtime");
    const inst = readJsonMaybe(path.join(base, "installation.json"));
    if (inst && inst.executable && fs.existsSync(inst.executable)) return inst.executable;
    const dirs = fs.existsSync(base) ? fs.readdirSync(base).filter((d) => d.startsWith("runtime-") && fs.existsSync(path.join(base, d, "UrhoXRuntime.exe"))) : [];
    if (!dirs.length) stop("找不到 Maker 本地运行时，先在 Maker 里装好本地预览");
    dirs.sort((a, b) => fs.statSync(path.join(base, b)).mtimeMs - fs.statSync(path.join(base, a)).mtimeMs);
    return path.join(base, dirs[0], "UrhoXRuntime.exe");
}

// 用本机运行时跑一个 validate 测试脚本，返回日志全文。dir 是项目目录（默认本项目；存档样本在临时 worktree 里跑）。
function runValidate(t, log, dir = ROOT) {
    const launch = readJsonMaybe(path.join(ROOT, "dev", "launch.json")) || { width: 480, height: 853 };
    const root = dir.replace(/\\/g, "/");
    const args = [t.entry, `-tapcode_dir=${root}`, "-skip_login", "-p=Res", "-tool_mode", "-w",
        `-width=${launch.width}`, `-height=${launch.height}`, "-validate", `-validate-test=${root}/scripts/${t.script}`,
        `-validate-frames=${t.frames || 4000}`, `-validate-timeout=${t.timeout || 280}`, "-validate-spike-threshold=60000"];
    console.log(`  跑 ${t.script}（${launch.width}×${launch.height}，最多 ${(t.timeout || 280) + 30} 秒）…`);
    fs.mkdirSync(path.dirname(log), { recursive: true });
    const fd = fs.openSync(log, "w");
    cp.spawnSync(runtimeExe(), args, { cwd: dir, stdio: ["ignore", fd, fd], timeout: ((t.timeout || 280) + 30) * 1000, windowsHide: true });
    fs.closeSync(fd);
    return fs.readFileSync(log, "utf8");
}

// 第 5 步：全量测试。跑项目自己的测试入口，必须见到 dev/release.json 里 test.must 的每一句，且失败 0 条。
function stepTest(rec) {
    head("第 5 步 全量测试");
    const t = cfg.test;
    if (!t) stop("dev/release.json 没写 test（测试入口、帧数、必须出现的结束语）");
    const log = path.join(TMP, "test.log");
    const commit = headCommit();
    const dirty = git(["status", "--porcelain", "--", "scripts"]);
    const started = now();
    const text = runValidate(t, log);
    const m = text.match(/INFO__VALIDATE_TEST__:(\w+)\|(\d+):(\d+):(\d+)/);
    const missing = (t.must || []).filter((s) => !text.includes(s));
    const le = text.match(/"lua_errors":\s*(\d+)/);   // 运行时自己的汇总；测试故意制造的报错不算
    const luaErrors = le ? Number(le[1]) : null;
    const sec = Math.round((now() - started) / 1000);
    const passed = m ? Number(m[2]) : 0, total = m ? Number(m[3]) : 0, failed = m ? Number(m[4]) : -1;
    const good = m && m[1] === "PASSED" && failed === 0 && total > 0 && !missing.length && !luaErrors;
    rec.test = { at: fmt(now()), ok: !!good, passed, total, failed, luaErrors, commit, dirty: !!dirty, sec, log: rel(log) };
    saveRec(rec);
    if (good) ok("测试", `${passed}/${total} 条断言全过，${(t.must || []).join("、")} 都有，Lua 报错 ${luaErrors === null ? "未统计" : luaErrors}，${sec} 秒（提交 ${commit}${dirty ? "，另有没提交的改动" : ""}）`);
    else {
        if (luaErrors) bad("测试", `运行时报了 ${luaErrors} 个 Lua 错误`);
        bad("测试", m ? `${m[1]}，断言 ${passed}/${total}，失败 ${failed}` : "没有测试结果（没跑起来或超时）");
        if (missing.length) bad("测试", `日志里没有：${missing.join("、")}（多半是帧数或超时给小了，后面的测试没跑到）`);
        const lines = text.split(/\r?\n/).filter((l) => /FAIL|stack traceback|attempt to/.test(l)).slice(0, 8);
        for (const l of lines) console.log("      " + l.slice(0, 200));
        console.log(`      完整日志：${rel(log)}`);
    }
}

// ---------------------------------------------------------------- 存档
// dev/release.json 的 save：file、match（存档版本号在哪个文件、怎么取）、samples（存档样本 Lua 文件）、
//   make（生成样本的测试：entry、script、frames、timeout，out 是脚本写到项目根的存档文件名前缀）。
// 样本文件是这里生成的 Lua 表，每个上线版本一组真存档，项目测试逐份读档（拾荒日记 T104）。读档永不清档，见 savekit README。

// 上一个上线过的版本（本次之前、记录里 done 了的最新一个）。
function prevRelease(rec) {
    return allRecs().filter((r) => r.done && cmpVer(r.version, rec.version) < 0).pop() || null;
}
// 存档版本号：commit 为空读工作区，否则读那次提交里的。
function saveVersionAt(commit) {
    const s = cfg.save;
    const file = path.join(ROOT, s.file);
    const text = commit ? git(["show", `${commit}:${s.file}`], { soft: true }) : (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null);
    const m = text && text.match(new RegExp(s.match));
    return m ? Number(m[1]) : null;
}
// 样本文件里的条目：[{release, version, name, text}]。
const SAMPLE_RE = /\{ release = "([^"]+)", version = (\d+), name = "([^"]+)", text = \[(=*)\[([\s\S]*?)\]\4\] \},?/g;
function readSamples() {
    const p = path.join(ROOT, cfg.save.samples);
    if (!fs.existsSync(p)) return [];
    return [...fs.readFileSync(p, "utf8").matchAll(SAMPLE_RE)].map((m) => ({ release: m[1], version: Number(m[2]), name: m[3], text: m[5] }));
}
function writeSamples(list) {
    list.sort((a, b) => cmpVer(a.release, b.release) || a.name.localeCompare(b.name, "en", { numeric: true }));
    const rows = list.map((e) => {
        let eq = "=";
        while (e.text.includes("]" + eq + "]")) eq += "=";
        return `    { release = "${e.release}", version = ${e.version}, name = "${e.name}", text = [${eq}[${e.text}]${eq}] },`;
    });
    const body = ["---@diagnostic disable",
        "-- 每个上线版本的真存档样本：dev/sumeru/release/release.js sample 生成，别手改；测试逐份读档，确认老玩家更新后存档照读。",
        "return {", ...rows, "}", ""].join("\n");
    fs.writeFileSync(path.join(ROOT, cfg.save.samples), body);
}

// 生成某个上线版本的存档样本：在那次发布测过的提交上开临时 worktree，跑 save.make 的脚本，收进样本文件（这一版已有的换掉）。
// 老提交里没有生成脚本时，拿当前的脚本放进去试（接口对不上就跑不出来，要手动补）。返回样本文件路径。
function stepSample(rec) {
    head(`存档样本 ${rec.version}`);
    const s = cfg.save;
    if (!s || !s.make) { info("存档样本", "dev/release.json 没写 save.make，跳过"); return null; }
    const commit = (rec.check && rec.check.commit) || (rec.test && rec.test.commit);
    if (!commit) stop(`${rec.version} 的记录里没有测过的提交`);
    const wt = path.join(os.tmpdir(), `sumeru-sample-${process.pid}`);
    git(["worktree", "add", "-q", "--detach", wt, commit]);
    try {
        const script = path.join(wt, "scripts", s.make.script);
        if (!fs.existsSync(script)) {
            info("存档样本", `${commit} 里没有 ${s.make.script}，用现在的`);
            fs.copyFileSync(path.join(ROOT, "scripts", s.make.script), script);
        }
        const log = path.join(TMP, "sample.log");
        const text = runValidate(s.make, log, wt);
        const files = fs.readdirSync(wt).filter((f) => f.startsWith(s.make.out) && f.endsWith(".json"));
        if (!files.length) {
            for (const l of text.split(/\r?\n/).filter((x) => /FAIL|stack traceback|attempt to/.test(x)).slice(0, 8)) console.log("      " + l.slice(0, 200));
            stop(`没生成存档（日志 ${rel(log)}）`);
        }
        const fresh = files.map((f) => {
            const body = fs.readFileSync(path.join(wt, f), "utf8").replace(/\0+$/, ""); // File:WriteString 末尾带一个 \0
            let v = null;
            try { v = JSON.parse(body).version; } catch (e) { stop(`${f} 不是 JSON`); }
            return { release: rec.version, version: Number(v), name: f.slice(s.make.out.length, -5), text: body };
        });
        writeSamples([...readSamples().filter((e) => e.release !== rec.version), ...fresh]);
        ok("存档样本", `${rec.version}（存档版本 ${fresh[0].version}，提交 ${commit}）：${fresh.map((e) => e.name).join("、")} 收进 ${s.samples}`);
        return s.samples;
    } finally {
        git(["worktree", "remove", "--force", wt], { soft: true });
    }
}

// 第 6 步：发布前检查，只读。有一项不过就停，不往下构建。
async function stepCheck(rec) {
    head("第 6 步 发布前检查");
    const before = fails;
    const st = cloudStatus();
    if (st.clean) ok("云端", "没有没提交的改动");
    else bad("云端", `有没提交的改动：${(st.files || []).map((f) => f.path).join("、")}（跑 sync）`);
    git(["fetch", "-q", "origin"]);
    const behind = Number(git(["rev-list", "--count", "HEAD..origin/main"]));
    if (behind) bad("本地", `比云端少 ${behind} 个提交（跑 sync）`); else ok("本地", "包含云端全部提交");
    const pj = projectJson();
    const next = nextVersion(pj.version, sparks());
    if (!next.version) bad("版本号", next.why);
    else if (rec.version === next.version) ok("版本号", `本次 ${rec.version}（${next.why}）`);
    else bad("版本号", `本次该是 ${next.version}（${next.why}），记录里是 ${rec.version}`);
    for (const a of appVersions()) {
        if (a.value === rec.version) ok("appVersion", `${a.file} = ${a.value}`);
        else bad("appVersion", `${a.file} = ${a.value || a.why}，应该是 ${rec.version}（跑 version）`);
    }
    const head0 = headCommit();
    if (!rec.test) bad("测试", "还没跑（跑 test）");
    else if (!rec.test.ok) bad("测试", `上次没过（${rec.test.at}），修好重跑`);
    else if (rec.test.commit !== head0) bad("测试", `测的是 ${rec.test.commit}，现在是 ${head0}，代码变过要重跑`);
    else ok("测试", `${rec.test.passed}/${rec.test.total} 全过（${rec.test.at}）`);
    if (cfg.save) {
        const cur = saveVersionAt(null);
        const prev = prevRelease(rec);
        const prevCommit = prev && ((prev.check && prev.check.commit) || (prev.test && prev.test.commit));
        const old = prevCommit ? saveVersionAt(prevCommit) : null;
        const have = [...new Set(readSamples().map((e) => e.release))];
        if (cur === null) bad("存档", `${cfg.save.file} 里读不到存档版本号（${cfg.save.match}）`);
        else if (prev && !have.includes(prev.version)) bad("存档", `${cfg.save.samples} 里没有上一版 ${prev.version} 的存档样本（跑 sample --version ${prev.version}），老玩家的档没验过不能发`);
        else {
            if (old !== null && old !== cur) info("存档", `存档版本 ${old} → ${cur}：只加字段不用升；升了要在修补表里写好每一步（读档永不清档，见 savekit README“版本修补”）`);
            ok("存档", `版本 ${cur}，测试读过 ${have.join("、") || "（还没有上线版本）"} 的存档样本`);
        }
    }
    if (rec.post && rec.post.reusedFrom) ok("公告稿", `沿用 ${rec.post.reusedFrom} 的：${rec.post.title}`);
    else {
        const n = readNotice(rec);
        if (n.problems.length) for (const p of n.problems) bad("公告稿", p);
        else if (!rec.post || !rec.post.draftId) bad("公告稿", "还没建草稿（跑 draft，或者沿用已发的跑 reuse --from 1.0.N）");
        else if (noticeDoc(rec, n).hash !== rec.post.hash) bad("公告稿", "日志.md 在建草稿之后改过（重跑 draft，再请开发者确认）");
        else if (!rec.approve || rec.approve.hash !== rec.post.hash) bad("公告稿", `开发者还没确认预览：${rec.post.previewUrl}`);
        else ok("公告稿", `已确认：${rec.post.title}`);
    }
    const vs = tapVersions();
    const busy = vs.find((v) => ["reviewing", "scheduled"].includes(v.status));
    if (busy) bad("TapTap 版本", `${busy.version} ${busy.status_label}：等它结束再发，别撤`);
    else ok("TapTap 版本", vs[0] ? `最新 ${vs[0].version} ${vs[0].status_label}` : "还没有版本");
    if (cfg.platforms === "1") ok("平台", "只上手机"); else bad("平台", `app_platforms = ${cfg.platforms}，应该只上手机（"1"）`);
    const phase = (pj.taptap_publish || {}).release_phase;
    if (phase === "public_test") bad("上架状态", "project.json 记的是「公开测试」：上次发布页点成了「改为公开测试」，先在发布页核对");
    else ok("上架状态", `${phase || "未记录"}（发布页只点「保持状态并更新版本」）`);
    const btn = await storeButton();
    if (btn === null) bad("详情页", "读不到 TapTap 详情页");
    else if (playable(btn)) ok("详情页", `按钮是“${btn}”，玩家能玩`);
    else bad("详情页", `按钮是“${btn || "没找到"}”，玩家现在玩不了，先查上架状态`);
    const pc = run("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
        `[Console]::OutputEncoding=[Text.Encoding]::UTF8; & '${path.join(ROOT, "dev", "sumeru", "publish-check.ps1")}'; exit $LASTEXITCODE`], { timeout: 300000 });
    const sum = (pc.out.match(/错误 \d+，警告 \d+/) || [""])[0];
    if (pc.code === 0) ok("物料", `publish-check ${sum || "通过"}`);
    else {
        bad("物料", `publish-check ${sum || "没跑完"}：`);
        for (const l of pc.out.split(/\r?\n/).filter((x) => /^\[ERROR\]/.test(x)).slice(0, 6)) console.log("      " + l);
    }
    const items = (tap("whats-new", "list", { page: 1, page_size: 50, status: "online" }).list || []);
    const olds = items.filter((i) => i.type === "announcement" && /^【更新公告】/.test(i.title || ""));
    const ov = tap("whats-new", "get-overview");
    const cap = (ov.capacity || []).find((c) => c.content_type === "announcement") || { used: 0, limit: 2 };
    if (olds.length) ok("公告位", `第 12 步会用新公告顶掉“${olds[0].title}”`);
    else if (cap.used < cap.limit) ok("公告位", `公告位 ${cap.used}/${cap.limit}，还有空位`);
    else bad("公告位", `公告位满了（${cap.used}/${cap.limit}），也没有旧的更新公告可换：请开发者定下线哪条`);
    const desc = localDesc();
    const words = reviewHits(desc);
    if (words.length) bad("简介", `有审核敏感词：${words.join("、")}（改 project.json 的 taptap_publish.description）`);
    else if (chars(desc) > cfg.review.descMax) info("简介", `${chars(desc)} 字，超过 ${cfg.review.descMax}：一类玩法写一行，别逐个列店名、地点（长了不好读，也更容易碰到敏感词）`);
    else ok("简介", `${chars(desc)} 字，没有审核敏感词`);
    const hits = scanGameWords();
    if (hits.length) info("游戏文字", `有审核敏感词，游戏内的也会被拒，删不删由开发者定：${hits.slice(0, 4).map((h) => `${h.file}:${h.line}「${h.word}」`).join("，")}${hits.length > 4 ? ` 等 ${hits.length} 处` : ""}`);
    else ok("游戏文字", "没有审核敏感词");
    rec.listing = { descSha: sha(desc), chars: chars(desc), at: fmt(now()) };
    rec.check = { at: fmt(now()), ok: fails === before, commit: head0 };
    saveRec(rec);
}

// 第 4–6 步一键：同步云端 → 写版本号 → 全量测试 → 发布前检查。
async function cmdPrepare(argv) {
    const rec = loadRec(argv);
    if (rec.verify) stop(`${rec.version} 已经上线了，不用再备包`);
    head(`备包 ${rec.version}：同步云端`);
    syncCloud();
    stepVersion(rec);
    stepTest(rec);
    if (fails) stop("测试没过，不往下走");
    await stepCheck(rec);
    if (fails) stop("发布前检查有不过的，先处理");
    console.log(`\n  可以构建了：先跟开发者说“开始构建，先别开发布页”，再调 maker_build_current_directory。`);
    console.log(`  构建完请开发者把发布页刷新后再点（开着的旧页面会把旧简介写回去）。`);
}

// 第 10 步：核对上线。先把发布页写的 project.json 同步下来，再看版本号、新包、TapTap 版本、详情页。
async function stepVerify(rec) {
    head(`第 10 步 核对上线（${rec.version}）`);
    if (rec.verify) { ok("上线", `已核对过：TapTap ${rec.verify.tapVersion}，spark ${rec.verify.spark}（${rec.verify.at}）`); return true; }
    const before = fails, waits = pendings;
    syncCloud();
    const pj = projectJson();
    const sp = sparks();
    const fresh = sp.filter((s) => Number(s.version_code) > rec.prev.spark);
    // 没新包就是发布页还没点：TapTap 上最新那个是旧的（可能是没发的空版本、上次被拒的），不评判，只等（1.0.10 时被误判成不过）。
    if (!fresh.length) { wait("包", `还没有新包（最新还是 spark ${sp[0] ? sp[0].version_code : "？"}）：发布页刷新后点了，过一两分钟再跑`); return false; }
    ok("包", `spark ${fresh[0].version_code}（${fmt(fresh[0].updated_at * 1000)}）`);
    if (fresh.length > 1) info("包", `这次出了 ${fresh.length} 个包（spark ${fresh.map((s) => s.version_code).reverse().join("、")}），发布页可能点了不止一次`);
    // 包出了，云端号就是这个包的号。上线认的是包和 TapTap 版本，号对不上不拦（1.0.13 就卡在这），提示一声、记下来当下次定号的锚点
    if (pj.version === makerOf(rec)) ok("Maker 版本", `${pj.version}（spark ${fresh[0].version_code}${pj.version === rec.version ? "" : `，本次记 ${rec.version}`}）`);
    else info("Maker 版本", `这个包是 ${pj.version}，定号时以为是 ${makerOf(rec)}：不影响上线，公告和 appVersion 照 ${rec.version}；号记下来，下次按包号定`);
    const vs = tapVersions();
    const v = vs[0];
    if (!v || v.version === rec.prev.tapVersion) wait("TapTap 版本", "还没有新版本");
    else if (v.status === "online") ok("TapTap 版本", `${v.version} 已上线`);
    else if (v.status === "reviewing") wait("TapTap 版本", `${v.version} 审核中：过几分钟再跑，不要在发布页重复点`);
    else if (v.status === "rejected") {
        const rj = noteRejection(rec, v, Number(fresh[0].version_code));
        bad("TapTap 版本", `${v.version} 被拒：${rj.reason}`);
        info("被拒了", "只改资料（简介等）：改好本地 project.json 跑 resubmit，用 taptap-cli 写进 TapTap 再提审，别回发布页点；要改代码：改完跑 renumber（重建版本号必 +1），再 prepare → 构建");
    } else bad("TapTap 版本", `${v.version} ${v.status_label}`);
    // 交给 TapTap 的简介是不是备包时本地那份（发布页开着的旧页面会写回旧简介）。
    if (rec.listing && v && ["reviewing", "online"].includes(v.status) && v.version !== rec.prev.tapVersion) {
        const t = tapDesc();
        if (sha(t) === rec.listing.descSha) ok("简介", `TapTap 上是备包时本地那份（${chars(t)} 字）`);
        else if (!t && v.status === "online") {
            // 上线后 TapTap 没有可编辑的草稿，资料模块的字段全是空的（1.0.14 审核很快、核对时已上线，误报“0 字”），改看详情页上的简介
            const desc = localDesc();
            const miss = sha(desc) === rec.listing.descSha ? await storeDescMissing(desc) : undefined;
            if (miss === undefined) bad("简介", "本地简介备包后改过，TapTap 已上线、读不到草稿：去详情页核对，不对就跑 resubmit");
            else if (miss === null) info("简介", "TapTap 已上线、没有草稿读不到简介，详情页也没打开：去详情页看一眼");
            else if (!miss.length) ok("简介", `详情页上是备包时本地那份（${rec.listing.chars} 字；已上线没有草稿，按详情页核对）`);
            else bad("简介", `详情页上找不到本地简介的这几行：${miss.join("、")}：发布页多半写回了旧简介，跑 resubmit`);
        }
        else bad("简介", `TapTap 上的简介（${chars(t)} 字）不是备包时本地那份（${rec.listing.chars} 字）：发布页多半写回了旧简介。审核中可以等结果，被拒了跑 resubmit`);
    }
    const dc = (pj.dc_publish_sync || {}).dcVersion;
    if (v && dc && dc !== v.version) info("发布页记录", `project.json 记的是 ${dc}，TapTap 最新是 ${v.version}`);
    const phase = (pj.taptap_publish || {}).release_phase;
    if (phase === "public_test") bad("上架状态", "发布页记的是「公开测试」：去发布页核对，应该是保持提供游玩");
    const btn = await storeButton();
    if (btn !== null && playable(btn)) ok("详情页", `按钮是“${btn}”，玩家能玩`);
    else bad("详情页", `按钮是“${btn || "读不到"}”，玩家可能玩不了`);
    if (fails > before || pendings > waits) return false;
    rec.verify = { at: fmt(now()), tapVersion: v.version, spark: Number(fresh[0].version_code), makerVersion: pj.version, sparks: fresh.map((s) => Number(s.version_code)), commit: headCommit() };
    saveRec(rec);
    return true;
}

// 第 11 步：发更新公告。只发第 3 步确认过、之后没改过的那份草稿；版本没上线不发。
function stepPost(rec) {
    head("第 11 步 发更新公告");
    if (rec.post && rec.post.momentId) { ok("更新公告", rec.post.reusedFrom ? `沿用 ${rec.post.reusedFrom} 的：${rec.post.url}` : `已经发过：${rec.post.url}`); return; }
    if (!rec.verify) stop("版本还没核对上线，不发公告");
    if (!rec.post || !rec.post.draftId) stop("还没建公告草稿（draft）");
    if (!rec.approve || rec.approve.hash !== rec.post.hash) stop("开发者还没确认这份预览，或确认后稿子又改过：先 draft，再请开发者确认、approve");
    const n = readNotice(rec);
    const { doc, hash } = noticeDoc(rec, n);
    if (hash !== rec.post.hash) stop("日志.md 在开发者确认之后改过：重跑 draft，再请开发者确认");
    const r = tap("community-management", "publish-community-topic-draft", { draft_id: rec.post.draftId, document: doc }, { yes: true, write: true, key: `${cfg.slug}-${rec.version}-publish` });
    if (!r.moment_id) stop("发帖没拿到 moment_id：先到论坛看一眼有没有发出去，别直接重跑");
    rec.post.momentId = String(r.moment_id);
    rec.post.url = `https://www.taptap.cn/moment/${r.moment_id}`;   // 挂活动与公告只认这种链接
    rec.post.status = r.publication_status;
    rec.post.publishedAt = fmt(now());
    saveRec(rec);
    ok("更新公告", `已发：${rec.post.url}（刚发的帖子在审核，可能只有自己看得到，不是失败，别重发）`);
}

// 第 12 步：换活动与公告。下线旧的更新公告 → 其他详情页置顶先取消 → 建新公告（置顶）→ 置顶还回去，新公告排第一条。
function stepPin(rec) {
    head("第 12 步 换活动与公告");
    if (!rec.post || !rec.post.momentId) stop("更新公告还没发");
    const url = rec.post.url;
    rec.pin = rec.pin || {};
    const online = () => (tap("whats-new", "list", { page: 1, page_size: 50, status: "online" }).list || []);
    const key = (s) => `${cfg.slug}-${rec.version}-pin-${s}`;
    let items = online();
    let mine = items.find((i) => i.url === url);
    if (!mine) {
        const olds = items.filter((i) => i.type === "announcement" && /^【更新公告】/.test(i.title || ""));
        if (!rec.pin.top) rec.pin.top = olds.length ? olds[0].top_types : ["app_detail"];
        if (!rec.pin.endTime) {
            const day = fmt(now() + cfg.post.pinDays * 864e5).slice(0, 10);   // 展示到那天北京时间 23:59:59
            rec.pin.endTime = Math.floor(Date.parse(`${day}T23:59:59+08:00`) / 1000);
        }
        rec.pin.offlined = rec.pin.offlined || [];
        for (const o of olds) {
            tap("whats-new", "update-status", { content_id: o.content_id, status: "offline" }, { yes: true, write: true, key: key(`off-${o.content_id}`) });
            rec.pin.offlined.push({ id: o.content_id, title: o.title });
            saveRec(rec);
            ok("下线", `旧的更新公告“${o.title}”`);
        }
        items = online();
        rec.pin.untopped = rec.pin.untopped || [];
        for (const o of items.filter((i) => (i.top_types || []).includes("app_detail"))) {
            if (!rec.pin.untopped.find((x) => x.id === o.content_id)) { rec.pin.untopped.push({ id: o.content_id, top: o.top_types, title: o.title }); saveRec(rec); }
            tap("whats-new", "save-top", { content_id: o.content_id, top_types: o.top_types.filter((t) => t !== "app_detail") }, { yes: true, write: true, key: key(`untop-${o.content_id}`) });
            ok("置顶", `“${o.title}”先取消详情页置顶，等下还回去`);
        }
        const ov = tap("whats-new", "get-overview");
        const cap = (ov.capacity || []).find((c) => c.content_type === "announcement");
        if (cap && cap.used >= cap.limit) stop(`公告位满了（${cap.used}/${cap.limit}）：请开发者定下线哪条`);
        const r = tap("whats-new", "create", { url, type: "announcement", label_type: "announcement", start_time: 0, end_time: rec.pin.endTime, top_types: rec.pin.top }, { yes: true, write: true, key: key("create") });
        rec.pin.contentId = r.content_id;
        saveRec(rec);
        ok("新公告", `已挂上，展示到 ${fmt(rec.pin.endTime * 1000).slice(0, 10)}，置顶 ${rec.pin.top.join("、") || "无"}`);
    } else if (!rec.pin.contentId) { rec.pin.contentId = mine.content_id; saveRec(rec); }
    for (const o of rec.pin.untopped || []) {
        if (o.restored) continue;
        tap("whats-new", "save-top", { content_id: o.id, top_types: o.top }, { yes: true, write: true, key: key(`retop-${o.id}`) });
        o.restored = true;
        saveRec(rec);
        ok("置顶", `“${o.title}”置顶已还原`);
    }
    const g = tap("whats-new", "get", { content_id: rec.pin.contentId });
    if (g.status === "online" && !g.invalid) ok("核对", `新公告在线（编号 ${rec.pin.contentId}）`); else bad("核对", `新公告状态 ${g.status}${g.invalid ? "，失效：" + g.invalid_reason : ""}`);
    if (g.title && g.title !== rec.post.title) info("卡片标题", `显示成了“${g.title}”，和帖子标题不一样（卡片标题改不了，不对只能换帖子）`);
    const ov = tap("whats-new", "get-overview");
    const slot = (ov.top_slots || []).find((s) => s.top_type === "app_detail");
    if (slot && (rec.pin.top || []).includes("app_detail")) {
        if (slot.content_ids[0] === rec.pin.contentId) ok("置顶顺序", "新公告排在详情页第一条");
        else info("置顶顺序", `详情页置顶是 ${slot.content_ids.join("、")}，新公告不在第一条`);
    }
    rec.pin.at = fmt(now());
    saveRec(rec);
}

// docs/更新日志/README.md 的版本表：没有“帖子”列就补上，再按版本加一行（已有就不动）。
function versionTable(text, rec, highlight) {
    const lines = text.split("\n");
    const hi = lines.findIndex((l) => /^\|\s*版本\s*\|/.test(l));
    if (hi < 0) return text;
    if (!/帖子/.test(lines[hi])) {
        lines[hi] = lines[hi].replace(/\s*$/, "") + " 帖子 |";
        lines[hi + 1] = lines[hi + 1].replace(/\s*$/, "") + "---|";
        for (let i = hi + 2; i < lines.length && lines[i].startsWith("|"); i++) lines[i] = lines[i].replace(/\s*$/, "") + "  |";
    }
    if (!lines.some((l) => l.startsWith(`| [${rec.version}]`))) {
        let end = hi + 2;
        while (end < lines.length && lines[end].startsWith("|")) end++;
        const post = rec.post && rec.post.url ? `[帖子](${rec.post.url})` : "";
        lines.splice(end, 0, `| [${rec.version}](${rec.version}/日志.md) | ${rec.verify.at.slice(0, 10)} | ${highlight} | ${post} |`);
    }
    return lines.join("\n");
}

// 第 13 步：版本表加一行、记下完成，提交本次的清单和记录，出发布报告。
function stepRecord(rec) {
    head("第 13 步 记录、提交");
    if (!rec.verify) stop("还没核对上线");
    const readme = path.join(LOGS, "README.md");
    const reused = rec.post && rec.post.reusedFrom;
    const highlight = reused ? (rec.post.note ? `${rec.post.note}（沿用 ${reused} 的公告）` : `沿用 ${reused} 的公告`)
        : (rec.post && rec.post.title ? rec.post.title : "").replace(/^【更新公告】\S+\s*/, "");
    if (fs.existsSync(readme)) {
        const before = fs.readFileSync(readme, "utf8");
        const after = versionTable(before, rec, highlight);
        if (after !== before) { fs.writeFileSync(readme, after); ok("版本表", `docs/更新日志/README.md 加了 ${rec.version}`); }
        else ok("版本表", "已经有这一行");
    }
    if (!rec.done) { rec.done = { at: fmt(now()) }; saveRec(rec); }
    let samples = null;
    if (cfg.save && cfg.save.make && !readSamples().some((e) => e.release === rec.version)) {
        try { samples = stepSample(rec); } catch (e) {
            if (!(e instanceof Stop)) throw e;
            bad("存档样本", `${e.message}（之后跑 sample --version ${rec.version} 补上，下次发布前检查会挡）`);
        }
    }
    const paths = [rel(path.join(LOGS, rec.version)), rel(readme), samples].filter((p) => p && fs.existsSync(path.join(ROOT, p)));
    git(["add", "--", ...paths]);
    const staged = git(["diff", "--cached", "--name-only", "--", ...paths]);
    if (staged) { git(["commit", "-q", "-m", `🔖 release: ${rec.version}（${reused ? `沿用 ${reused} 公告` : `公告 ${rec.notice}`}）上线`, "--", ...paths]); ok("提交", `${headCommit()}（发布清单、记录、版本表${samples ? "、存档样本" : ""}）`); }
    else ok("提交", "没有要提交的");
    console.log(`\n✅ ${rec.game} ${rec.version} 已上线`);
    console.log(`  TapTap 版本 ${rec.verify.tapVersion}（已上线）· 主包 spark ${rec.verify.spark}`);
    console.log(`  安卓 / iOS：玩家能玩 · 电脑端：未上架`);
    console.log(`  更新公告：${rec.post && rec.post.url ? rec.post.url : "没发"} · 活动与公告：${rec.pin && rec.pin.contentId ? (reused ? `照旧挂 ${reused} 的` : `已换成 ${rec.notice}`) : "没换"}`);
}

// 被拒后只改资料（简介等，代码不动）重提：不回发布页点（它会交表单里的旧简介），直接用 taptap-cli 改 TapTap 草稿、预检、提审。
// 不带 --yes 只预览：简介差异、写入预演、预检结果。开发者点头后带 --yes 再跑，才写简介、提审。
async function cmdResubmit(argv) {
    const rec = loadRec(argv);
    head(`被拒重提（${rec.version}）`);
    if (rec.verify) stop(`${rec.version} 已经上线了`);
    const v = tapVersions()[0];
    if (!v || v.status !== "rejected") stop(`TapTap 最新版本是 ${v ? `${v.version} ${v.status_label}` : "没有"}，不在被拒状态，不用重提`);
    const r = lastRejection(v.version) || { at: 0, reason: v.status_reason || "" };
    info("拒审原因", r.reason || v.status_reason || "没返回");
    const desc = localDesc();
    const words = reviewHits(desc);
    if (words.length) stop(`本地简介里还有审核敏感词：${words.join("、")}。先改 project.json 的 taptap_publish.description`);
    const key = `${cfg.slug}-${rec.version}-resubmit-${r.at}`;
    const cur = tapDesc();
    if (cur === desc) ok("简介", `TapTap 上已经是本地这份（${chars(desc)} 字）`);
    else {
        const change = { changes: [{ field_id: "description", value: desc, expected: cur }] };
        if (!argv.yes) { tap("app", "save-changes", change, { dryRun: true, key: `${key}-desc` }); ok("简介", `TapTap 上 ${chars(cur)} 字 → 本地 ${chars(desc)} 字，写入预演通过（还没写）`); }
        else {
            tap("app", "save-changes", change, { yes: true, write: true, key: `${key}-desc` });
            if (tapDesc() !== desc) stop("简介写完读回不一样，停下来查");
            ok("简介", `已写进 TapTap 并读回核对（${chars(cur)} → ${chars(desc)} 字）`);
        }
    }
    const flags = (tap("app", "get-app-module", { module_id: "platform-status" }).fields) || {};
    const dist = Object.entries(flags).filter(([k]) => k.startsWith("region_flag_")).map(([k, f]) => `${k.replace("region_flag_", "")} ${(f.value_labels || {})[String(f.current_value)] || f.current_value}`);
    if (dist.length) info("分发状态", `${dist.join("、")}（不改）`);
    const schedule = { kind: "immediate" };
    const snapV = tap("app", "prepare-review-snapshot").version_id;
    const pre = tap("app", "precheck-app-review", { release_schedule: schedule });
    if (pre.version_id && snapV && pre.version_id !== snapV) stop("复核期间版本变了，重跑 resubmit");
    for (const b of pre.blockers || []) bad("阻塞项", b.message || JSON.stringify(b));
    if (fails) stop("有阻塞项，先处理");
    ok("阻塞项", "无");
    const st = pre.preaudit_status || (pre.preaudit_passed ? "passed" : "");
    if (st === "passed") ok("机审", "通过");
    else if (st === "rejected") info("机审", "没过：不挡提交，但提了多半还会被拒");
    else info("机审", "这次没跑出结论：可以稍后重跑，也可以直接提");
    if (!argv.yes) { console.log("\n  开发者点头后加 --yes 再跑：写简介、提审（审核通过后立即上线）"); return; }
    const s = tap("app", "submit-app-review", { release_schedule: schedule }, { yes: true, write: true, key });
    const after = tapVersions()[0];
    if (!after || after.status !== "reviewing") stop(`提审后读回是 ${after ? after.status_label : "没有版本"}，提交结果 ${JSON.stringify(s).slice(0, 200)}`);
    ok("提审", `${after.version} 审核中`);
    markHandled(rec, "resubmit");
    rec.listing = { descSha: sha(desc), chars: chars(desc), at: fmt(now()) };
    rec.resubmits = [...(rec.resubmits || []), { at: fmt(now()), tapVersion: after.version, descChanged: cur !== desc }];
    saveRec(rec);
    info("下一步", "后台循环跑 finish（退出码 2 = 审核中），过了自动收尾");
}

// 被拒后要改代码重建：被拒那个包已经用掉了号，重建出来必是下一号（见 nextVersion），所以整次发布改号。
// 记录目录、版本号跟着改，appVersion 在 prepare 里写；已确认、已发的公告不动（公告号照旧）；
// prev.spark 改成被拒那个包，第 10 步才认得出重建的新包；测试、检查清掉，prepare 重跑。
async function cmdRenumber(argv) {
    const rec = loadRec(argv);
    head(`改号（${rec.version}）`);
    if (rec.verify) stop(`${rec.version} 已经上线了，不用改号`);
    syncCloud();
    const pj = projectJson();
    const sps = sparks();
    const next = nextVersion(pj.version, sps);
    if (!next.version) stop(next.why);
    const to = next.version, from = rec.version;
    const sp = sps[0];
    if (to === from) {
        // 本次号本来就排在包号后面（见 nextVersion），号不用动，只换包号和起点包
        rec.maker = next.maker;
        if (sp) rec.prev = { ...rec.prev, spark: Number(sp.version_code) };
        markHandled(rec, "renumber");
        delete rec.test;
        delete rec.check;
        saveRec(rec);
        ok("版本号", `本次还是 ${to}，不用改号；重建的包是 Maker ${next.maker}`);
        ok("下一步", "改好代码后 prepare → 构建 → 发布页刷新后点更新 → finish");
        return;
    }
    if (cmpVer(to, from) < 0) stop(`云端 ${pj.version} 比记录里的 ${from} 还旧，先跑 status 查清楚`);
    const oldDir = path.join(LOGS, from), newDir = path.join(LOGS, to);
    if (fs.existsSync(newDir)) stop(`${rel(newDir)}/ 已经有了`);
    if (git(["mv", rel(oldDir), rel(newDir)], { soft: true }) === null) fs.renameSync(oldDir, newDir);
    const re = new RegExp(`(?<![\\d.])${from.replace(/\./g, "\\.")}(?![\\d.])`, "g");
    const list = path.join(newDir, "发布清单.md");
    if (fs.existsSync(list)) fs.writeFileSync(list, fs.readFileSync(list, "utf8").replace(re, to));
    const readme = path.join(LOGS, "README.md");
    if (fs.existsSync(readme)) fs.writeFileSync(readme, fs.readFileSync(readme, "utf8").split(`| [${from}](${from}/日志.md)`).join(`| [${to}](${to}/日志.md)`));
    rec.version = to;
    rec.maker = next.maker;
    if (sp) rec.prev = { ...rec.prev, spark: Number(sp.version_code) };
    rec.renumbered = [...(rec.renumbered || []), { from, to, at: fmt(now()) }];
    markHandled(rec, "renumber");
    delete rec.test;
    delete rec.check;
    saveRec(rec);
    const paths = [rel(oldDir), rel(newDir), rel(readme)];
    git(["add", "-A", "--", ...paths]);
    git(["commit", "-q", "-m", `🔖 release: ${from} 被拒重建，改记 ${to}（公告 ${rec.notice} 照旧）`, "--", ...paths]);
    ok("改号", `${from} → ${to}：记录目录、发布清单、版本表已改，提交 ${headCommit()}；公告 ${rec.notice} 不动`);
    ok("下一步", "改好代码后 prepare → 构建 → 发布页刷新后点更新 → finish");
}

async function cmdVerify(argv) { const rec = loadRec(argv); await stepVerify(rec); }
async function cmdTest(argv) { const rec = loadRec(argv); stepTest(rec); }
async function cmdCheck(argv) { const rec = loadRec(argv); await stepCheck(rec); }
async function cmdVersion(argv) { const rec = loadRec(argv); stepVersion(rec); }
async function cmdSync() { head("同步云端"); syncCloud(); }
async function cmdPost(argv) { const rec = loadRec(argv); stepPost(rec); }
async function cmdPin(argv) { const rec = loadRec(argv); stepPin(rec); }
async function cmdRecord(argv) { const rec = loadRec(argv); stepRecord(rec); }
async function cmdSample(argv) {
    const rec = loadRec(argv);
    if (!cfg.save) stop("dev/release.json 没写 save");
    const p = stepSample(rec);
    if (p) info("提交", `样本写进了 ${p}，看过后自己提交`);
}

// 第 10–13 步一键：核对上线 → 发公告 → 换活动与公告 → 记录提交。没上线就停在第 10 步，过几分钟重跑。
async function cmdFinish(argv) {
    const rec = loadRec(argv);
    if (!(await stepVerify(rec))) { if (!fails) process.exitCode = 2; stop("还没上线，过几分钟再跑 finish"); }
    stepPost(rec);
    stepPin(rec);
    if (fails) stop("换活动与公告有不过的，先处理再跑 finish");
    stepRecord(rec);
}

const COMMANDS = {
    status: [cmdStatus, "版本一览：云端、本地、代码 appVersion、TapTap 版本、最新的包、详情页能不能玩、下一个版本号、进行中的发布（只读）"],
    new: [cmdNew, "第 1 步：同步云端、算出本次版本号，建 docs/更新日志/<版本>/（发布清单、公告稿、发布记录）"],
    draft: [cmdDraft, "第 2 步：公告稿写好后，上传配图、在 TapTap 建好草稿，给出预览链接"],
    approve: [cmdApprove, "第 3 步：开发者看过预览说可以发之后，记下确认"],
    reuse: [cmdReuse, "第 2–3 步的另一条路：不另写公告，沿用已发的（--from 1.0.N，默认上一版；--note 写这版改了什么，进版本表）"],
    prepare: [cmdPrepare, "第 4–6 步一键：同步云端 → 写 appVersion → 全量测试 → 发布前检查"],
    finish: [cmdFinish, "第 10–13 步一键：核对上线 → 发公告 → 换活动与公告 → 记录提交、发布报告"],
    sync: [cmdSync, "单步：提交发布页写在云端的 project.json，合并云端提交"],
    version: [cmdVersion, "单步（第 4 步）：写 appVersion"],
    test: [cmdTest, "单步（第 5 步）：全量测试"],
    check: [cmdCheck, "单步（第 6 步）：发布前检查（只读）"],
    verify: [cmdVerify, "单步（第 10 步）：核对上线"],
    post: [cmdPost, "单步（第 11 步）：发更新公告"],
    pin: [cmdPin, "单步（第 12 步）：换活动与公告"],
    record: [cmdRecord, "单步（第 13 步）：版本表、提交、发布报告"],
    resubmit: [cmdResubmit, "被拒后只改资料：本地简介写进 TapTap、预检；加 --yes 才写入并提审（不回发布页点）"],
    sample: [cmdSample, "补存档样本：在这一版测过的提交上让机器人玩几天，存档收进 save.samples（--version 指定哪一版；第 13 步会自动做）"],
    renumber: [cmdRenumber, "被拒后要改代码重建：被拒的包用掉了号，重建是下一号，整次发布改号（记录目录、清单、版本表），公告照旧"],
};

async function main() {
    const args = process.argv.slice(2);
    const argv = {};
    const rest = [];
    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--version") argv.version = args[++i];
        else if (args[i] === "--yes") argv.yes = true;
        else if (args[i] === "--from") argv.from = args[++i];
        else if (args[i] === "--note") argv.note = args[++i];
        else rest.push(args[i]);
    }
    const name = rest[0];
    if (!name || !COMMANDS[name]) {
        console.log("用法：node dev/sumeru/release/release.js <命令> [--version 1.0.N] [--yes] [--from 1.0.N] [--note 说明]\n");
        for (const [k, [, d]] of Object.entries(COMMANDS)) console.log(`  ${k.padEnd(8)} ${d}`);
        process.exitCode = name ? 1 : 0;
        return;
    }
    loadConfig();
    await COMMANDS[name][0](argv);
    if (!["status", "sync"].includes(name)) {
        const recs = allRecs();
        const rec = argv.version && fs.existsSync(recPath(argv.version)) ? readJson(recPath(argv.version)) : recs[recs.length - 1];
        if (rec) console.log(`\n  下一步：${nextStep(rec)}`);
    }
    if (fails) process.exitCode = 1;
    else if (pendings && !process.exitCode) process.exitCode = 2;
}

// 被 require 时只导出函数（自测、查字段用），直接运行才跑命令。
module.exports = { loadConfig, loadRec, saveRec, readNotice, noticeDoc, versionTable, fillLog, bump, noticeOf, cmpVer, playable, redact, nextStep, tap, scanGameWords, reviewHits };
if (require.main === module) main().catch((e) => {
    if (e instanceof Stop) console.log(`\n  [停] ${e.message}`);
    else console.log(`\n  [出错] ${redact(e.stack || e)}`);
    if (!process.exitCode) process.exitCode = 1;
}).finally(() => {
    for (const f of fs.existsSync(TMP) ? fs.readdirSync(TMP) : []) if (/^req-\d+-\d+\.json$/.test(f)) fs.rmSync(path.join(TMP, f), { force: true });
});
