// 把论坛稿件（docs/更新日志/<版本>/日志.md、docs/社区公告/*.md）转成 taptap-cli 建帖子草稿用的 JSON。
// 用法：node dev/sumeru/publish/md2draft.js <稿件.md> <输出.json> <appId> [draftId] [--group=<子版块ID>] [--personal]
//   不带 draftId：出建草稿用的 {title,contents,forum_bindings}；
//   带 draftId：出改草稿、发布用的 {draft_id,document:{…}}（整份文档，绑定原样带上）。
//   默认子版块「综合」（0）、官方身份。输出要放在当前目录里（--data @文件 只认当前目录），比如 .tmp/draft.json。
// 转换规则见 论坛公告.md「建草稿」：# 标题→title；## →heading；连续的 - 行→一个 list；**粗体**；> 引用和其他非空行→paragraph。
// 图片行（![…](…)）跳过：正文配图要先 +upload-image 拿到地址和宽高，再手动加 image 节点。遇到 <!-- 就停（模板末尾的写作规则）。
const fs=require("fs");
const args=process.argv.slice(2);
const flags=Object.fromEntries(args.filter(a=>a.startsWith("--")).map(a=>{const [k,v]=a.slice(2).split("=");return [k,v===undefined?true:v]}));
const [src,out,appId,draftId]=args.filter(a=>!a.startsWith("--"));
if(!src||!out||!appId){console.error("用法：node md2draft.js <稿件.md> <输出.json> <appId> [draftId] [--group=<子版块ID>] [--personal]");process.exit(1)}

const inline=t=>t.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map(p=>p.startsWith("**")&&p.endsWith("**")?{text:p.slice(2,-2),bold:true}:{text:p});
let title="";const nodes=[];let list=null;let skipped=0;
for(const raw of fs.readFileSync(src,"utf8").split(/\r?\n/)){
 const l=raw.trimEnd();
 if(l.startsWith("<!--"))break;
 if(!l.trim()){list=null;continue}
 if(l.startsWith("# ")){title=l.slice(2).trim();continue}
 if(l.startsWith("![")){skipped++;continue}
 if(l.startsWith("## ")){list=null;nodes.push({type:"heading",info:{level:2},children:[{text:l.slice(3).trim()}]});continue}
 if(l.startsWith("- ")){
  if(!list){list={type:"list",children:[]};nodes.push(list)}
  list.children.push({type:"list-item",info:{"li-level":1},children:inline(l.slice(2).trim())});continue
 }
 list=null;nodes.push({type:"paragraph",children:inline(l.replace(/^>\s*/,"").trim())});
}
if(!title){console.error("稿件没有一级标题（# …），帖子标题取不到");process.exit(1)}

const doc={title,contents:JSON.stringify(nodes),
 forum_bindings:[{app_id:String(appId),group_label_id:String(flags.group||"0"),identity:flags.personal?"personal":"official",honor:{mode:"inherit"}}]};
fs.writeFileSync(out,JSON.stringify(draftId?{draft_id:String(draftId),document:doc}:doc));
console.log("标题："+title);
console.log("正文节点 "+nodes.length+" 个"+(skipped?"，跳过图片 "+skipped+" 张（要配图先 +upload-image）":"")+" → "+out);
