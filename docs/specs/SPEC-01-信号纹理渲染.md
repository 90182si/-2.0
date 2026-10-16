# SPEC-01 · 信号纹理驱动 GPU 着色（M4~M5 / T1.1~T1.7，附 §2.8 compute 后端 T1.8~T1.10）

> 前置：T2.2（netId 分配）已完成。目标：时钟 tick 等高频路径只写"信号纹理"一个 texel；几何层（MultiMesh 重建）只在内容变化时执行。
> 全局约束见主文档《大改造技术方案.md》。本 SPEC 不依赖改造二完成度（但共享 netId）。
>
> **分层归属（强制，见主文档 §5）**：
> - `core/manager/sw_signal_texture.gd` → **L2 服务层**：后端可插拔点（T1.8 接口化后 CPU/GPU 后端都在这层），对上只暴露 set_net_color/flush/get_texture 端口，不感知建筑/电路语义。
> - `render/sw_style_texture.gd` → **L2 服务层**：启动时扫描 L0 定义（.tres region）一次性构建，与渲染器同样只经 styleId 端口对接。
> - `sw_grid_draw.gdshader`、`calBuffer` 改动 → **L3 表现层**：只消费 part 字典契约（字段即 ABI，见主文档 §5.4）；禁止在 shader/渲染器里写元件类型特判。
> - tick 路径切换（T1.5）落点在 **L3 调度**（sw_build_layer）调用 **L2 写端口**，电路求值本身仍归 **L1**，不得把颜色逻辑倒灌进 L1。

---

## 0. 背景与现状锚点

### 0.1 渲染端
**`render/sw_grid_draw.gdshader`**（全文 41 行）：`custom_data = INSTANCE_CUSTOM`，fragment 用 custom_data(x,y,z,w)=图集 rect，`srcColor.rgb*color.rgb` 乘法混色（**乘法混色无法染黑为亮**——历史陷阱，保持语义不变）。防渗色 pad 0.5px 逻辑必须原样保留。

**`render/sw_multi_mesh_instance_2d.gd`**：
- `_fill_instance(...)`（约 L208-227）：写 transform 8 float + color 4 + rect 4（use_colors 时 16/实例，否则 12）。
- `calBuffer()`：工作线程；ByContent 分支遍历 `curMapData`（区块全部建筑）调 `render_able.getRenderParts()`，part 字典字段：`{rect, offset, rotation, color, use_color}`（见 0.3）。
- `bufferCalFinish(newBuffer, showCount)`：主线程 `multimesh.set_buffer` + `visible_instance_count` + `emit_changed`。
- 双缓冲 `_pingPongBuffers` 已存在（此前优化），保留。

### 0.2 部件来源
**`circuit/build_compoent/sw_build_compoent_renderable.gd` `_buildRenderParts()`**（已加脏标记缓存）产出三类 part：
1. 底座（buildHasBase）：rect=atlasBuildBase.region，color=in_loop?LoopColor:默认，use_color 标志；
2. 引脚端子（buildDefine.build_pin）：`net = pinNetMap[posmod(p.pin_dir+rotation,4)]`，颜色来自 `SwCommon.GetWireColor(net.wireGroup.wireName)` 按低/高电平取 `colorArr[0]/[1]`；电线中间段在 `wire==true` 时 `continue` 跳过；
3. 主体贴图（buildHasAtlas）：drawRect，rotation 按 buildAtlasRotable。

### 0.3 高频触发链（要被切断的）
`layers/build/sw_build_layer.gd _process`（L369-382）：CLOCK_GAP_TIME=1/60，×2 节拍 → 逐时钟 `onPressed(true)` + `buildSignalChanged` 累积 `changedBuilds` → `getNotifyChunkPosArr` → `sw_draw_manager.updataChunks` → `_refreshChunkContent` → `drawMap` → 整块重算。
点击按钮/开关路径（L322-348）同构。

---

## 1. T1.1 styleTex 构建（低风险，先行）

### 新文件 `render/sw_style_texture.gd`
```gdscript
class_name SWStyleTexture extends RefCounted
# texel[styleId] = vec4(region.x, region.y, region.size.x, region.size.y)
var image:Image                 # FORMAT_RGBA32F（若目标平台 storage 受限，本任务仅采样用，可用 FORMAT_RGBAF 等价物；Godot Image 无 RGBAF，用 RGBA32F）
var texture:ImageTexture
var styleCount:int = 0
func register_rect(r:Rect2) -> int      # 去重登记，返回 styleId
func build_texture() -> void            # register 完毕后调用；宽向上取整到 2^n 不必需，一维 texelFetch 即可
func get_style_id(r:Rect2) -> int       # 已登记则返回既有 id
```
纹理尺寸：`width = styleCount`，height=1。**NEAREST 采样**（CanvasItemTexture filter 由材质设置，或 shader 内 texelFetch 不受影响）。

### 登记来源（枚举所有 region 的唯一途径）
1. `res/build_define_registry.tres`（已存在的注册表）遍历全部 `SWBuildDefine`，登记：
   - `atlasBuildBase.region`（若引用非 null）
   - `atlasTextureOn.region` / `atlasTextureOff.region`
   - 每个 `build_pin` 元素的 `wire_pin.region`（注意 wire_pin 是 SWBuildPinDefine 的 **const preload 共享资源**，全局只登记一次即可，但按 define 遍历天然去重）
2. renderable 的 `drawRect`（运行时由 `resetBuildState` 赋值 `atlasTextureOff.region`，与上面来源重合，无需单独登记）。
3. 启动时机：主场景 `_ready` 中、任何建筑创建之前执行一次。

### 验收
- 打印 styleCount 与去重命中日志；抽样 10 个 rect 的 styleId 回查 texel 值与原 rect 逐分量相等。
- **本任务不改渲染**，纯新增。

---

## 2. T1.2 SWSignalTexture（CPU 后端）

### 新文件 `core/manager/sw_signal_texture.gd`
```gdscript
class_name SWSignalTexture extends RefCounted
const MAX_NETS := 65536           # 超限 push_error（float 精度 2^24 上限，65536 留足余量）
const TEX_COLS := 4096            # net_id 按 4096 列 × 16 行 2D 网格排布，规避 16384 边长上限 GPU
var image:Image                   # FORMAT_RGBA32F, width=TEX_COLS, height=MAX_NETS/TEX_COLS
var texture:ImageTexture
var netCount:int = 0              # 由 T2.2 的 registeredNetMax 同步

func init(nets:int) -> void        # 分配 image/texture，全 texel 置透明
func set_net_color(netId:int, c:Color) -> void:
    image.set_pixel(netId % TEX_COLS, netId / TEX_COLS, c)  # 2D 网格坐标，与 shader 换算一致
    texture.update(image)          # 每次 update 全图上传——MAX_NETS=65536*16B=1MB/次。
                                   # 优化（本任务内做）：脏区间标记，本帧多次 set 合并为一次 update；
                                   # 或用 Image.update 区块？Godot 无局部 update API → 用"每帧批量提交"：
                                   # set_net_color 只写 image 并标脏，flush() 在帧末统一 texture.update。
func flush() -> void               # 由主循环每帧调用一次（仅脏时 update）
func get_texture() -> ImageTexture
```
> **决策**：`set_net_color` 不立即 update，改为脏标记 + 每帧 `flush()`，避免 1MB×翻转数的上传放大。时序上 flush 在 `_process` 末尾（绘制前），同帧生效。

颜色值来源：与 `_buildRenderParts` 端子逻辑完全一致——`SwCommon.GetWireColor(net.wireGroup.wireName)[0 or 1]`。新增辅助：
`circuit/build_compoent/sw_build_compoent_renderable.gd` 增加 static/成员方法 `get_net_color(net:SWNet) -> Color`，供本纹理与部件缓存两处共用（**颜色单一真源**）。

### 验收
- 单元测试：set→flush→get_image 读回一致；同帧 1000 次 set 只触发 1 次 update（计数器断言）。

---

## 3. T1.3 shader 改造

### `render/sw_grid_draw.gdshader` 新 uniform 与逻辑
```glsl
uniform sampler2D styleTex;    // texel[styleId] = (x, y, w, h)
uniform sampler2D signalTex;   // signalTex[texel(netId)] = rgba 颜色（TEX_COLS×TEX_ROWS 网格）
uniform int signalCols;        // = SWSignalTexture.TEX_COLS，由脚本 set_shader_parameter 注入
```
fragment 流程（保持像素输出不变）：
1. `sid = int(custom_data.x + 0.5)`；`rect = texelFetch(styleTex, ivec2(sid, 0), 0)`；用 rect.x/y/z/w 替代原 custom_data 四分量参与 UV 计算（pad 逻辑原样）。
2. `nid = int(custom_data.y + 0.5)`；
   - `nid >= 0`：`color = texelFetch(signalTex, ivec2(nid % signalCols, nid / signalCols), 0) * COLOR;`（信号色 × 烘焙 tint，mask/选中叠加走 COLOR）
   - `nid < 0`：`color = COLOR;`（非信号部件回退）
3. 乘法混色与 alpha 合并公式**逐字保留**原实现。

### 验收（像素回归安全网）
- 固定存档 + 固定相机，改造前后各截一图：`viewport.get_texture().get_image().save_png()`，用 `Image` 逐像素 `==` 比对（允许 0 差异；如浮点纹理解码引入 ±1 噪声，放宽到 |d|<=1 并记录）。脚本放 `test/render_pixel_parity.gd`（GUT 或独立 Scene 脚本均可）。
- 覆盖元件：电线A/B、交叉、桥梁、隧道、端子、非门、与门、非门(NAND)、按钮、开关、时钟、灯泡、寄存器、底座、in_loop 红态、选中 mask 态、HOLDING 半透明态。

---

## 4. T1.4 calBuffer 写入改造（几何层）

### part 字典契约变更
`_buildRenderParts()` 产出的每个 part **新增键**：
- `"net_id": int`（端子 part 填 `net.netId`，T2.2 分配；底座/主体填 `-1`）
- `"style_id": int`（由 rect 经 `SWStyleTexture.get_style_id(rect)` 查询）
- `"flags": int`（bit0=in_loop，bit1=holding，预留 bit2+）
- `color` 字段语义变更：底座/主体=烘焙最终色；端子=烘焙 tint（mask 色与默认白）——**最终信号色不再烘焙进 part**。

### `_fill_instance` 新布局
custom_data 写入：`[style_id, net_id, flags, 0]`；COLOR 写入烘焙色 rgba（net_id>=0 时 signalTex 会再乘 COLOR——见 T1.3，故端子烘焙色 = mask_color，非端子 = 原最终色）。

### calBuffer 内读取
part 字典在热循环按 key 取值已有开销；本任务同时把 `part["offset"]` 等改为局部变量一次性取出（微优化随手做，不做大改）。

### 关键绑定事务（与 T2.2 联动）
`updateBuildCircuit` 返回 affectBuilds 后（sw_draw_manager.updataChunks 之前）：
1. netId 已重编号（T2.2）；
2. 全量 flush signalTex：遍历全部 net，`set_net_color(netId, get_net_color(net))`；
3. 再触发 chunk 重绘（几何层拿到的 custom_data 与 texel 一致）。
实现位置：`layers/build/sw_build_layer.gd` 中所有 `updataChunks` 调用点之前加一行 `_signalTexSync()`（封装 2 的逻辑）。

### 验收
- 像素回归全过（T1.3 脚本复跑）；放置/删除/旋转后颜色正确；工作线程内**禁止**触碰 Image/ImageTexture（只写 float buffer，遵守主线程 Resource 约束）。

---

## 5. T1.5 tick 路径切换（本改造的核心收益）

### 改动
1. `SWNet` 增加：`var paintedSignal:int = -999  # 上次写入纹理的电平，-999=未画`。
2. `circuit/sw_cirucit_control.gd buildSignalChanged`：返回值不变；**新增**在 BFS 结束后遍历 `notifyPosArr∪{build}` 每个建筑的输入 net（去重），`if net.curSignal != net.paintedSignal: SWSignalTexture.set_net_color(net.netId, get_net_color(net)); net.paintedSignal = net.curSignal`。
3. `sw_build_layer._process` 时钟分支（L377-382）：**删除** `getNotifyChunkPosArr(changedBuilds)+updataChunks`；保留求值与上述纹理更新（2 已在 buildSignalChanged 内完成，这里只需 `SWSignalTexture.flush()`）。
4. 点击按钮/开关路径（L325-348）同样处理。
5. **保留**内容变化路径：放置/删除/旋转/加载仍走 updataChunks → drawMap（几何层），并执行 T1.4 的 `_signalTexSync()`。

### 悬空/未连接 net
未连 drivers 的 net（电线孤段）：维持现有默认色（GetWireColor[0]），首次入图时写入一次即可（几何层 sync 时覆盖）。

### 验收（性能门禁）
- 场景：≥50 个时钟 + 密集电线。指标（performance/sw_performance_monitor.gd 记录，写入 docs/metrics.md）：
  - `drawMap` 调用次数：tick 期间**不再增长**；
  - `getRenderParts` 调用次数：tick 期间为 0（仅几何层事件出现）；
  - 帧率：对比改造前（历史基线：时钟密集时曾降至 10fps），目标 ≥55fps（或至少 3 倍提升并留档说明）。
- 行为回归：按钮点击即时变色（同帧）；时钟翻转肉眼无延迟；存档加载颜色正确。

---

## 6. T1.6 flags 迁移

in_loop（bit0）/holding（bit1）现由烘焙色/alpha 表达的部分迁移：
- in_loop 红色：底座与端子在 in_loop 时为 LoopColor（非信号驱动）→ 仍走烘焙色路径（net_id=-1），**无需 shader 分支**。仅当未来需要"信号色与 in_loop 叠加"时才启用 flags 采样，本任务只把 flag 写进 custom_data.z 备用。
- HOLDING 半透明（ByHold 模式 color.a*=0.85，`_get_instance_color`）：属于烘焙色，无需迁移。
- 结论：T1.6 收敛为"flags 位写入 + 文档说明"，shader 不加分支。验收=像素回归仍全过。

---

## 7. T1.7 性能验收报告

- 输出 `docs/metrics.md`：改造前后 getRenderParts 调用数 / drawMap 次数 / 帧率 / 内存（ping-pong buffer 大小）四项对比。
- 场景脚本复用 `performance/performance_test.gd`。

---

## 8. §2.8 compute 后端（T1.8~T1.10，M9 可选，规模墙触发才做）

### T1.8 接口化
`core/manager/sw_signal_texture.gd` 重构为基类（虚方法 set_net_color/flush/get_texture/init）+ `SWSignalTextureCPU`（现实现）；工厂函数按 `RenderingServer.get_rendering_device() != null` 与项目设置 `sw_render/signal_backend`（枚举 auto/cpu/gpu）选择。调用点零改动。

### T1.9 GPU 纹理桥接（只写纹理，不算信号）
1. `rd = RenderingServer.get_rendering_device()`；`RDTextureFormat`：DATA_FORMAT_R32G32B32A32_SFLOAT（compute 端 image2D 限定符 rgba32f），usage=`TEXTURE_USAGE_SAMPLING_BIT | TEXTURE_USAGE_STORAGE_BIT | TEXTURE_USAGE_CAN_UPDATE_BIT`。
2. `var tex := Texture2DRD.new(); tex.texture_rd_rid = rd.texture_create(fmt, view)`；材质 signalTex 参数换为该纹理。
3. compute shader（`render/sw_signal_compute.glsl`，`#[compute] #version 450`）：输入 net 颜色数组（storage buffer，CPU 在 set_net_color 时写入 PackedFloat32Array，帧末 buffer_update），imageStore 写 texel。
4. dispatch 在 `_process` 末（flush 等价物）；与 canvas 读顺序接受 ≤1 帧延迟（电平颜色无感）；如需严格序，用 viewport `_render_callback` PRE_TRANSPARENT。
5. 验收：与 CPU 后端逐 texel 对拍一致；Compatibility/WebGL2 下自动回退 CPU 后端（get_rendering_device()==null 断言）。

### T1.10 L2 信号计算上 GPU
- gate storage buffer：`[op:int32, dst:int32, a:int32, b:int32, level:int32]` ×N（拓扑层号 level 由编译器输出——需在 SWBoolCompiler 补 level 字段）。
- net 值 storage image 双缓冲（prev/next），逐层 dispatch（每层一次 compute_list，L=最长链）；帧边界执行寄存器锁存 pass（比较 D_prev 写 Q）。
- CPU 侧 readback：仅按需（in_loop 面板/存档/LED 数值显示）`rd.buffer_get_data`，且批量化（帧计数器节流 ≥30 帧）。
- 对拍：复用 ir_parity_test 框架，GPU 结果经批量 readback 与 CPU 求值逐拍比对。
- **风险**：Web 无 RD 必回退；移动端 RGBA32F storage 受限——后端选择器需实测降级。

---

## 9. 本 SPEC 全局禁区

1. 工作线程（calBuffer）内禁止访问 Image/ImageTexture/任何 Resource 派生对象。
2. signalTex 写端必须收敛在 SWSignalTexture 单例，调用点散落即视为不合格（T1.8 替换前提）。
3. 像素回归脚本在 T1.3/T1.4 每次提交前必须跑。
4. 乘法混色语义（shader 乘法 + 染黑陷阱）不允许改动。
