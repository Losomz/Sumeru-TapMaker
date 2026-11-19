// 把论坛稿件（docs/更新日志/<版本>/日志.md、docs/社区公告/*.md）转成 taptap-cli 建帖子草稿用的 JSON。
// 用法：node dev/sumeru/publish/md2draft.js <稿件.md> <输出.json> <appId> [draftId] [--group=<子版块ID>] [--personal] [--images=<图片表.json>]
//   不带 draftId：出建草稿用的 {title,contents,forum_bindings}；
//   带 draftId：出改草稿、发布用的 {draft_id,document:{…}}（整份文档，绑定原样带上）。
//   默认子版块「综合」（0）、官方身份。输出要放在当前目录里（--data @文件 只认当前目录），比如 .tmp/draft.json。
//   --images：{"宣传图.jpg":{"url":…,"width":…,"height":…}}，键是稿件里 ![…](键) 的地址，值是 +upload-image 的返回；
//   有对应的图片行转成 image 节点，没有的跳过。发布流水线（release/release.js）会自动上传再传进来。
// 转换规则见 论坛公告.md「建草稿」：# 标题→title；## →heading；连续的 - 行→一个 list；**粗体**；> 引用和其他非空行→paragraph。
// 遇到 <!-- 就停（模板末尾的写作规则）。
const fs=require("fs");

const inline=t=>t.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map(p=>p.startsWith("**")&&p.endsWith("**")?{text:p.slice(2,-2),bold:true}:{text:p});

// 稿件文字 → {title, nodes, skipped}；images 是上面的图片表。
function convert(text,images){
 images=images||{};
 let title="";const nodes=[];let list=null;let skipped=0;
 for(const raw of text.split(/\r?\n/)){
  const l=raw.trimEnd();
  if(l.startsWith("<!--"))break;
  if(!l.trim()){list=null;continue}
  if(l.startsWith("# ")){title=l.slice(2).trim();continue}
  const img=l.match(/^!\[([^\]]*)\]\(([^)]+)\)/);
  if(img){
   list=null;const m=images[img[2]];
   if(m&&m.url&&m.width&&m.height)nodes.push({type:"image",info:{img_url:m.url,width:m.width,height:m.height,description:img[1]},children:[{text:""}]});
   else skipped++;
   continue;
  }
  if(l.startsWith("## ")){list=null;nodes.push({type:"heading",info:{level:2},children:[{text:l.slice(3).trim()}]});continue}
  if(l.startsWith("- ")){
   if(!list){list={type:"list",children:[]};nodes.push(list)}
   list.children.push({type:"list-item",info:{"li-level":1},children:inline(l.slice(2).trim())});continue
  }
  list=null;nodes.push({type:"paragraph",children:inline(l.replace(/^>\s*/,"").trim())});
 }
 return {title,nodes,skipped};
}

// 建草稿用的文档；draftId 有值时包成改草稿、发布用的格式。
function toDocument(conv,appId,opts){
 opts=opts||{};
 const doc={title:conv.title,contents:JSON.stringify(conv.nodes),
  forum_bindings:[{app_id:String(appId),group_label_id:String(opts.group||"0"),identity:opts.personal?"personal":"official",honor:{mode:"inherit"}}]};
 return opts.draftId?{draft_id:String(opts.draftId),document:doc}:doc;
}

module.exports={convert,toDocument};

if(require.main===module){
 const args=process.argv.slice(2);
 const flags=Object.fromEntries(args.filter(a=>a.startsWith("--")).map(a=>{const i=a.indexOf("=");return i<0?[a.slice(2),true]:[a.slice(2,i),a.slice(i+1)]}));
 const [src,out,appId,draftId]=args.filter(a=>!a.startsWith("--"));
 if(!src||!out||!appId){console.error("用法：node md2draft.js <稿件.md> <输出.json> <appId> [draftId] [--group=<子版块ID>] [--personal] [--images=<图片表.json>]");process.exit(1)}
 const images=flags.images?JSON.parse(fs.readFileSync(flags.images,"utf8")):{};
 const conv=convert(fs.readFileSync(src,"utf8"),images);
 if(!conv.title){console.error("稿件没有一级标题（# …），帖子标题取不到");process.exit(1)}
 fs.writeFileSync(out,JSON.stringify(toDocument(conv,appId,{group:flags.group,personal:flags.personal,draftId})));
 console.log("标题："+conv.title);
 console.log("正文节点 "+conv.nodes.length+" 个"+(conv.skipped?"，跳过图片 "+conv.skipped+" 张（要配图先 +upload-image，用 --images 传进来）":"")+" → "+out);
}
