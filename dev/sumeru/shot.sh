#!/usr/bin/env bash
# 本地截图 + 运行时报错检查：直接用 Maker 已安装的 UrhoXRuntime 跑 scripts/dev/shot-<场景>.lua。
# 用法：bash dev/sumeru/shot.sh home [帧数=120] [宽] [高]；宽高默认取 dev/launch.json。
# 产出：.tmp/shots/<场景>.png 与 .tmp/shots/<场景>.json（validate 报告），并打印过滤噪音后的错误。
set -u
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd -W)"
SIZE="$(node -e 'let c={};try{c=require(process.argv[1])}catch(e){};console.log((c.width||480)+" "+(c.height||853))' "$ROOT/dev/launch.json")"
SCENE="${1:-home}";FRAME="${2:-120}";W="${3:-${SIZE% *}}";H="${4:-${SIZE#* }}"
EXE="$(node -e 'console.log(require(process.env.USERPROFILE+"/.taptap-maker/runtime/installation.json").executable)')"
OUT="$ROOT/.tmp/shots";mkdir -p "$OUT"
# UI 布局位置：Maker 控制台只扫 assets/，scripts/ 下（框架 scripts/sumeru/ 除外）的 .ui.json 后台看不到；完整检查见 ui-check.ps1。
BAD="$(cd "$ROOT" && find scripts -name "*.ui.json" -not -path "scripts/sumeru/*" 2>/dev/null)"
if [ -n "$BAD" ]; then echo "警告：以下 UI 布局放在 scripts/ 下，Maker 控制台看不到，连同 .meta 平移到 assets/ 下同一相对路径（见 scripts/sumeru/toolkit/uikit/MAKER_UI.md）：";echo "$BAD"|sed "s/^/  /";fi
rm -f "$OUT/$SCENE.png" "$OUT/$SCENE.json"
timeout 150 "$EXE" "dev/shot-$SCENE.lua" "-tapcode_dir=$ROOT" -tool_mode -nosound \
 "-screenshot=$OUT/$SCENE.png" "-screenshot-frame=$FRAME" -skip_login -p=Res -w "-width=$W" "-height=$H" \
 -validate "-validate-frames=$((FRAME+30))" -validate-timeout=120 -validate-spike-threshold=2000 \
 "-validate-output=$OUT/$SCENE.json" > "$OUT/$SCENE.log" 2>&1
node -e '
const fs=require("fs");const [png,json]=process.argv.slice(1);
console.log(fs.existsSync(png)?"png: "+png+" ("+fs.statSync(png).size+" bytes)":"png: MISSING");
if(!fs.existsSync(json)){console.log("report: MISSING");process.exit(1)}
const r=JSON.parse(fs.readFileSync(json,"utf8"));const noise=["[ShaderError]","Frame time spike","Could not initialize audio"];
let bad=0;for(const [ph,v] of Object.entries(r.phases||{}))for(const e of v.errors||[]){if(noise.some(n=>e.message.includes(n)))continue;bad++;console.log(" ["+ph+"/"+e.category+"] f"+e.frame+": "+e.message.slice(0,600))}
if((r.missing_resources||[]).length){bad++;console.log(" missing:",r.missing_resources)}
console.log("frames="+r.frames_completed+" result="+r.result+(bad?" -> 有问题":" -> 无脚本错误"));
' "$OUT/$SCENE.png" "$OUT/$SCENE.json"
grep -a "\[UI\]\|\[App\]\|stack traceback\|ERROR" "$OUT/$SCENE.log" | head -20
