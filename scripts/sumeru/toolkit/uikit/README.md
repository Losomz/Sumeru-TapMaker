# UIKit

入口为 `require("sumeru.toolkit.uikit.UIKit")`，负责 JSON 面板、宿主和组件生命周期。以下经验属于 UrhoX UI / NanoVG 绘制层，可随框架迁移到其他项目；不是对引擎参考库的修改。

## 接入配置

JSON 放在 `assets/ui/`，Lua Controller 放在 `scripts/ui/`，两者采用相同的相对路径即可使用下方默认配置。Maker 后台不扫描 `scripts/`；旧项目迁移、不同路径的适配及编辑器预览限制见 [Maker UI 目录与迁移说明](MAKER_UI.md)。

框架不引用任何业务模块。项目在注册面板前调用一次 `Configure`，把宿主判定、路径约定和项目控件注入进来：

```lua
local UIKit=require("sumeru.toolkit.uikit.UIKit")
local Components=require("sumeru.toolkit.uikit.ComponentRegistry")

UIKit:Configure({
 host=function(app) return app.inGame and "game" or "main" end, -- 当前业务宿主 Shell 名
 allows=function(def,app) return true end,                      -- 面板在当前阶段是否允许出现
 panelRoot="ui/panels",          -- 面板与 Shell：<root>/<key>/<key>.ui.json，控制器 ui.panels.<key>.<key>
 componentRoot="ui/components",  -- 未登记组件按 <root>/<slug>/<slug>.ui.json 查找
 shellComponents={game={"FrameworkButton","MyButton"}},           -- 各 Shell 预加载的组件
})
-- 项目自己的控件：Lua Widget 用 RegisterWidget，JSON 组件用 RegisterTemplate（均为首次使用时才加载）。
Components:RegisterWidget("MyButton",function() return require("ui.MyButton") end)
Components:RegisterTemplate("Card","ui/components/card/card.ui.json","ui.components.card.card")

UIKit:RegisterPanel("home",{shell="main",layer=UIKit.Layers.PhasePage})
UIKit:Attach(app,metrics)
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `host(app)` | 始终 `"main"` | 返回当前宿主 Shell 名，变化时卸载旧 Shell 与其页面 |
| `allows(def,app)` | 始终允许 | 面板在当前阶段是否允许打开、显示和保留缓存 |
| `panelRoot` | `ui/panels` | 未显式写 `template`/`controller` 的面板和 Shell 按此推导路径 |
| `componentRoot` | 不设 | 不设时未登记组件直接报错 |
| `shellComponents` | `{}` | 按 Shell 名列出预加载组件 |
| `toast` | 不设（默认样式） | 内置提示的底图、文字和样式覆盖；`false` 关闭内置提示，见 [通用提示 Toast](#通用提示-toast) |

- 框架内置控件只有 `FrameworkButton`、`FrameworkToggle`、`FrameworkScrollView`。
- `Configure` 必须在 `RegisterPanel` 之前调用；配置在 `Destroy` 后保留。
- App 约定：`app.dirty` 为真时下一帧刷新全部可见页面；`metrics(app)` 返回 `w,h,vw,vh,safe{left,right},top,map,capsule,background`。

项目需要为所有 JSON 控件注入统一外观时，可调用 `require("sumeru.toolkit.uikit.Json").SetWidgetInitializer(fn)`。回调接收 Widget，在每次加载模板时遍历执行，包含动态条目的控件；不设置时保持默认行为。业务布局仍保存在 JSON 中。

## 通用提示 Toast

框架内置一条通用提示。它在 `Attach` 时自动注册为面板 `sumeru-toast`，挂在 overlay 宿主的 Toast 层，所以项目里必须有 overlay 宿主。业务调用 `UIKit:ShowNotice(text,duration)` 即可，不用自己写提示面板。

- 第三个参数 `color` 可选，只改这一条的字色，例如好消息绿、坏消息红：`UIKit:ShowNotice("+¥30",nil,{90,120,60,255})`。不传就用皮肤字色。

**由框架负责，配置改不了**：
- 量文字、折行，底板随行数长高并居中；
- 新提示立即替换旧的，文字相同也重播动画；
- 不传时长时按字数定时长；
- 提示不拦截点击。

**默认样式**（`style` 中的键）：

| 项 | 默认 |
|---|---|
| 字号 `fontSize` / 行高 `lineHeight` | 16 / 1 倍 |
| 内边距 `padX` / `padY` | 左右 16，上下 10 |
| 宽度 `minWidth` / `maxWidth` / `margin` | 短字收窄，最窄 160；最宽取 min(屏宽 − 2×24, 400)，超出就折行 |
| 高度 `minHeight` / `warnLines` | 随行数长高，最矮 48。不限行数，不裁字；超过 3 行时日志提醒文案太长 |
| 位置 `anchorY` | 水平居中，底板中心在屏高 42% 处，多出的行上下对称长 |
| 动画 `fadeIn` / `fadeOut` / `rise` | 淡入 0.15 秒并上移 12，淡出 0.3 秒再上移 24 |
| 时长 `minDuration` / `maxDuration` | 不传时长时取 1.2 + 0.12×字数，限制在 2～5 秒 |

默认外观是深色半透明底、2 像素描边，文字用主题默认字体、浅米色。

**在初始化时覆盖**：写在 `Configure` 的 `toast` 字段里。`background`、`text` 整组替换默认外观，`style` 只覆盖写到的项：

```lua
UIKit:Configure({ ...,
 toast={
  background={image="image/ui/toast.png",slice={20,20,20,20}}, -- 常用：九宫格底图，切片按上、右、下、左写图片像素
  text={font="sans",color={244,227,189,255}},                  -- 常用：字体和字色
  style={fontSize=18,anchorY=.3},                              -- 少用：只改写到的项
 },
})
```

- 不传底图时，`background` 可写 `color`、`borderColor`、`borderWidth`、`borderRadius`，用纯色底。
- `toast=false` 关闭内置提示。

**老项目迁移**：项目如果自己在 Toast 层注册过提示面板，同步框架后会同时弹出两条提示。删掉自己的面板及其 `.meta`，把外观写进 `toast`；暂时不迁移就传 `toast=false`。

布局 `toast/toast.ui.json` 是框架内部文件，放在 `scripts/` 下。游戏能加载它，但它不会出现在 Maker 后台的 UI 文档列表里。项目不要改这个文件。

## 按钮动效 pop

`components/Controls.lua` 里的框架按钮默认是 lift：悬停时往上抬一点，不放大。想要“悬停放大、按下缩小、松手回弹”，用可选的 pop。不开就不变，已有项目同步后照旧。

**框架按钮**：传 `motion="pop"`，倍数可以单独改：

```lua
local Controls=require("sumeru.toolkit.uikit.components.Controls")
local btn=Controls.Button{text="出发",motion="pop",hoverScale=1.06,onClick=go}
```

**不是 Button 的控件**（Panel 拼的按钮、卡片、拖拽块、和画面分开的点击区）：在建控件之前把 props 交给 `Controls.Pop`：

```lua
local visual=UI.Panel{flexGrow=1,pointerEvents="none",children=kids}   -- 放大的那一层
local hit=UI.Panel(Controls.Pop({width=200,height=56,onClick=go,children={visual}},{target=visual}))
```

- `target`：放大哪个控件，可以是控件本身，也可以是 `function(w) return 控件 end`；不传就放大控件自己。点击区和画面分开时指向画面那一层，点击区就不跟着变大变小，按在边上也不会一缩就滑出去。
- `hoverScale` / `pressedScale`：覆盖默认的 1.05 / 0.95；`disabled=true` 只关动效，点击照常。
- 放大以 `target` 自己的 `transformOrigin` 为中心（默认居中）；它原本有 `scale` 时按原值再乘。
- 只有鼠标移进来才算悬停，手机上只有按下缩小、松手回弹；只认主键；移开或取消回到原大小。
- 原有的 `onPointerEnter/Leave/Down/Up/Cancel` 照常调用；原来没有 `onPointerDown/Up` 时照旧往父控件冒泡，滚动和拖拽不受影响。
- 参数在 `Controls.Motion.pop`：悬停 1.05、按下 0.95；悬停 0.12 秒、按下 0.07 秒、松手 0.22 秒带一点回弹（`easeOutBack`）。

## 文字自适应底板

内置 Toast 已经用 `TextFit` 处理了自适应。项目自己的气泡、提示条这类「底板 + 一段文字」的控件，用固定宽高时文字一长就会被裁掉。`TextFit` 按实际文字算出底板尺寸，字号不变：

```lua
local TextFit=require("sumeru.toolkit.uikit.TextFit")
local cache={}
local w,h=TextFit.Apply(bubble,label,text,{
 fontSize=15,fontFamily="my-font",lineHeight=1.2,  -- 与 Label 的字体参数保持一致
 maxWidth=300,minWidth=140,minHeight=46,padX=12,padY=6,
},cache)
bubble:SetStyle({left=(screenW-w)/2})  -- 用返回的宽高定位
```

- 单行放得下（文字宽 + 左右内边距 ≤ `maxWidth`）时底板收窄到文字宽度；放不下时按 `maxWidth` 换行，底板随行数增高。
- 结果不小于 `minWidth`/`minHeight`；文字 Label 绝对定位在底板内，必须设 `whiteSpace="normal"` 才能折行。
- 测量与 Label 渲染共用 `UI.MeasureTextFit`。同一个 `cache` 下文字不变时只命中缓存，可以每帧调用；字体晚于首帧加载完成时会自动重测。
- 只要尺寸不改控件时用 `TextFit.Measure(text,opt,cache)`，返回 `width,height,textWidth,textHeight,wrapped`。
- 底板带 `scale` 变换时，传入未缩放的设计尺寸，返回值再乘缩放系数用于定位。

## 九宫格内部出现细线

### 现象和原因

图片本身没有线，拉伸后沿切片边界出现极细、断续的线，颜色可能随背后的场景变化。

当前官方 `Widget:RenderSlicedImage` 分别用九个矩形绘制各块图片。开启几何边缘抗锯齿时，每块的边缘都可能形成半透明过渡；内部接缝两侧的覆盖不足，便会透出后面的画面。缩放、小数坐标可能影响它的明显程度，但不能仅凭这些现象断言原因。

2026-10-18 的 360×640 本地实机对照中，同一炮台面板、同一图片、同一布局下：

- 官方默认绘制可复现右侧切片接缝。
- 仍调用官方九宫格，仅关闭该次绘制的几何边缘抗锯齿后，接缝消失；对应空白区域的像素恢复为底板纯色。
- 整图绘制也没有该接缝，但会改变边角拉伸效果，因此不作为九宫格的默认替代。

这个结论针对已复现的内部接缝，不代表所有细线都来自九宫格，也不足以认定所有引擎版本都有同样问题。

### 默认处理：全局开启，拼接局部关闭

保留官方切片算法，在目标控件实例上包装绘制方法：

```lua
local Panel=require("urhox-libs/UI/Widgets/Panel")

-- 仅关闭切片接合边的抗锯齿，结束后恢复调用前的状态。
local function renderJoinedSlices(widget,nvg,...)
 nvgSave(nvg)
 nvgShapeAntiAlias(nvg,0)
 Panel.RenderSlicedImage(widget,nvg,...)
 nvgRestore(nvg)
end

-- sheet 为 JSON 创建的目标 Panel 实例。
sheet.RenderSlicedImage=renderJoinedSlices
sheet:SetProp("backgroundFit","sliced")
sheet:SetProp("backgroundSlice",{20,20,20,20}) -- 上、右、下、左；按素材填写。
```

不要改只读的 `urhox-libs/` 参考副本，运行时可能加载内置的另一份。也不要为了一个接缝全局替换官方组件方法。

`nvgSave` / `nvgRestore` 必须成对使用；不要在结束时直接写 `nvgShapeAntiAlias(nvg,1)`，因为调用前的状态未必是开启。该开关控制几何路径边缘，不是文字抗锯齿、纹理过滤或引擎 MSAA 的总开关。局部关闭也可能使贴图外围的几何边缘更硬，应检查实际尺寸下的外轮廓。

全局 UI 默认保持抗锯齿，避免圆角、斜线和矢量图形变得生硬。若做全局对照，必须在每帧 `nvgBeginFrame` 之后设置；只在初始化时设置会被新帧重置。对照结束后移除临时覆盖。

### 分段场景背景与九宫格分开处理

同一背景分成多段、由多个 `overflow="hidden"` 容器裁剪时，裁剪边缘或各段布局取整也可能造成接缝。这不是官方九宫格。仅关闭图片路径的抗锯齿不一定能消除裁剪边缘。

需要保持分区伸缩时，可在单一背景控件内按共享边界连续绘制各段纹理，局部关闭几何边缘抗锯齿，并保留原有源图坐标、分区比例和整体父级裁剪。不要通过整图任意拉伸掩盖问题。这个方案仍需单独实机确认，不能借用九宫格的验证结论。

### 排查顺序

1. 检查原图、实际切片参数和当前运行时的绘制实现；区分素材线条、路径接缝和裁剪接缝。
2. 确认当前窗口确实加载了修改后的代码。预览工具报告的会话可能与项目独立启动脚本的进程不同，应核对实际进程和日志。
3. 保持图片和布局一致，对照默认绘制、局部关闭抗锯齿、整图绘制；读取引擎截图，必要时比较接缝像素。静态图片拼接不能证明运行时已经修复。
4. 保留验证有效的最小修复，恢复全局绘制状态，按项目约定清理临时测试产物。没有画面证据时明确标记尚未确认。
