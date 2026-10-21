# 性能验收报告

## 改造一：信号纹理驱动 GPU 着色

### 架构变更

- **时钟 tick 路径**：从 O(chunk 几何重算) 降为 O(翻转 net 数) 增量纹理写入
- **custom_data 格式**：从 `[rect.x, rect.y, rect.w, rect.h]` 改为 `[style_id, net_id, flags, 0]`
- **新增纹理**：
  - `styleTex`（`SWStyleTexture`）：1×N 像素，N = 已注册 region 数（动态，由 `build_from_registry` 决定），FORMAT_RGBAF
  - `signalTex`（`SWSignalTexture`）：65536×1 像素，FORMAT_RGBAF（每 net 一列，RGBA 编码信号颜色）
- **shader 采样**：片段着色器通过 `custom_data.x` 查 styleTex 取 atlas UV rect，通过 `custom_data.y` 查 signalTex 取信号颜色

### 性能指标

| 指标 | 改造前 | 改造后 | 备注 |
|------|--------|--------|------|
| `getRenderParts`/tick | O(chunk 全部建筑) — 每次 calBuffer 遍历 `curMapData` 全量调用 | 0（tick 期间不再调用） | tick 仅写 signalTex 像素，不触发几何重算；`_renderPartsDirty` 脏标记缓存保证仅几何层事件（放置/删除/旋转/连接）时重建 |
| `drawMap`/tick | 每 tick 调用（时钟翻转→区块重绘→全量 calBuffer） | 0（tick 期间不再调用） | tick 路径不经过 `drawMap`；仅在几何层变更（`_refreshChunkContent`/`process_load_chunk`）时调用 |
| `signalTex flush`/tick | N/A | O(1) texture.update（脏时） | `flush()` 每帧最多一次 `texture.update`，写入量 = O(翻转 net 数) 像素 |
| 帧率 | 待测 | 目标 ≥55 fps | 需实测，性能面板 `SWPerformanceMonitor` 已含 FPS 颜色阈值（≥55 绿/≥30 黄/<30 红） |
| ping-pong buffer 大小 | 单 buffer，每帧 realloc + 清零 | 2 × `maxInstances × 16 × 4` 字节/chunk | 见下方计算 |

### Ping-Pong Buffer 大小计算

```
CHUNK_SIZE        = 16
n                 = 16 × 16 = 256
MAX_RENDER_PARTS  = 6
maxInstances      = 256 × 6 = 1536
float/实例        = 16（use_colors=true：transform 8 + color 4 + custom_data 4）
单 buffer 字节    = 1536 × 16 × 4 = 98,304 B ≈ 96 KB
ping-pong 总字节  = 2 × 96 KB = 192 KB/chunk
```

### 纹理内存开销

| 纹理 | 尺寸 | 格式 | 大小 |
|------|------|------|------|
| `styleTex` | styleCount × 1 | RGBAF | styleCount × 16 B（通常 < 1 KB） |
| `signalTex` | 65536 × 1 | RGBAF | 65536 × 16 B = 1 MB |

### 静态计数器

为验收测试添加了以下静态计数器（不持久化，进程内有效）：

| 计数器 | 位置 | 说明 |
|--------|------|------|
| `SWBuildCompoentRenderable.s_get_render_parts_call_count` | `circuit/build_compoent/sw_build_compoent_renderable.gd` | `getRenderParts()` 被 `calBuffer` 调用的累计次数 |
| `SWMultiMeshInstance2D.s_draw_map_call_count` | `render/sw_multi_mesh_instance_2d.gd` | `drawMap()` 被调用的累计次数 |

测试时可在任意时刻读取这两个 static var 的值进行断言。

### 测试场景

> 待补充：实际运行后填入具体数据

- 电路规模：_待补充_
- 时钟数量：_待补充_
- 电线密度：_待补充_
- 实测帧率：_待补充_
- `getRenderParts` 调用数/tick：_待补充_
- `drawMap` 调用数/tick：_待补充_
- `signalTex flush` 次数/tick：_待补充_

---

## 改造二：电路求值切 IR（T2.5 getValue 切 slot + push 化，M6）

### 架构变更

- **求值后端**：从「`getValue` 递归 pull 表达式树」切换为「查询编译后扁平 IR 的 slot 值 + push 传播」，由 `SWCircuitControl.useIR` 单开关回退。T2.5 落地时默认 `false`（对拍灰度），T2.6 起默认 `true`（IR 为主路径）。
- **寄存器时序唯一真相**：`OP_LATCH` 经 `latch_meta[slot]` 直读组件 `qState`（弃用 `_latch_prev` 双缓冲死机制）。
- **段式增量编译**：`SWBoolCompiler` 实例跨批次复用（slot/指令全局递增不重置），`segments[circuitID] -> {start,end,builds}` + `slotMap[build.id*4+dir] -> slot`；`SWBoolProgram.evaluate_range(start,end)` 区间不动点迭代（`MAX_SETTLE=64`）。
- **push 化**：`buildSignalChanged` 拆两趟（Pass A 结构 BFS → `evaluate_range` 刷新 slot → Pass B `reCalSignals` 读新 slot → `_pushDriverNets` 写回 net + 传播电线）。wired-AND 多驱 net 复刻树「末位驱动者胜」语义，并无条件刷新电线（修正 `OP_OUT` 预写 `net.curSignal` 使旧守卫恒假的电线陈旧 bug）。
- **本期不删树**：`SWCircuitStruct.args` 树退役留待对拍长期稳定后另做；`useIR=false` 回退路径与主路径同受 GUT 保护。

### 静态计数器

| 计数器 | 位置 | 说明 |
|--------|------|------|
| `SwCommon.evalStructCallCount` | `com/sw_common.gd` | `EvalStruct`（树 pull）被调用的累计次数，进程内有效 |

### 验收结果（GUT headless 全量）

| 用例 | 结果 | 证据 |
|------|------|------|
| `test_ir_tick_bypasses_evalstruct` | PASS | `useIR=true` 事件/tick 路径 `evalStructCallCount` delta = **0**（树求值完全旁路） |
| `test_parity_adder_save`（纯组合、电线密集） | PASS | 逐拍双跑（开关翻转 + 24 拍时钟）**零差异** |
| `test_parity_counter_save`（含寄存器时序） | PASS | 逐拍双跑 **零差异** |
| `test_parity_selfcheck_tree_vs_tree` | PASS | tree-vs-tree 自对拍证明测试方法学确定性 |
| `verilog_parity_test` | PASS | 3 tests / 868 asserts（emit 适配非-LED `OP_OUT` 跳过后不回归） |
| `test_circuit_led` + `test_ir_out_slots` | PASS | 2 tests / 852 asserts（适配 latch_meta/新 `OP_LATCH` 语义） |

对拍门禁口径：快照比较可观测功能态（非争议建筑 `signal_state`、寄存器 `qState`、单驱 net `curSignal`），排除两类「最后写回者胜」的纯视觉歧义——① wired-AND 多驱争议 net 的原始 `curSignal` 及其电线；② 交叉电线 WIRE_BRIDGE 单 `signal_state` 字段跨 `v_net`/`h_net` 两 net 且电平不一致时的着色。两 net 各自 `curSignal`（单驱）仍独立比对，功能覆盖不受影响（详见 `docs/specs/SPEC-02-IR与Verilog.md` §5）。

### 对拍调试期定位并修复的真实编译器 bug

1. `_emit_nary` 多输入 NAND 级联：`NAND(NAND(a,b),c)=(a&b)|~c ≠ NOT(a&b&c)` → 改为链式恒 `OP_AND` + 末尾单个 `OP_NOT`。
2. 空 args NAND/NOT 常量：树 `OP_NAND = 1 - EvalArgsAnd`，空 args `→ 1`；编译器原发 `_emit_const(0)` → 改 `_emit_const(1)`。修复后「逐表达式节点 slot 值 == 树 pull 值」差异归零。
3. wired-AND 多驱 net push 写回顺序 → 取 `getDrivers()` 末位驱动者（复刻树 last-writer）。
4. 事件后电线视觉陈旧（`OP_OUT` 预写 `net.curSignal` 使 `_pushDriverNets` 守卫恒假跳过电线）→ 无条件写回并传播。差异由 36 拍降至 0（含 WIRE_BRIDGE 交叉歧义纳入排除口径后）。

---

## 改造二·续：T2.6 拓扑序发射 + 单趟收敛

### 架构变更

- **编译期拓扑排序**：`SWBoolCompiler._topo_sort_builds()` 基于 `noticeMap` 做 Kahn 排序，按依赖顺序发射指令。时序元件（`isSequential()`，如寄存器）的**出边不计入组合依赖图**，与 `detect_combinational_loops` 口径一致，使「计数器 Q→adder→D→Q」这类合法时序反馈不会被误判成组合环而整段踢出拓扑路径。
- **段元数据新增 `iters`**：`segments[circuitID] = {start, end, builds, iters}`。无组合环的段 `iters=1`（单趟即收敛）；任一建筑被 `in_loop` 标记的段仍为 `MAX_SETTLE=64`，保留不动点迭代以匹配树 pull 语义。
- **运行时按 `iters` 分派**：`SWBoolProgram._run_span(start,end,iters)`，`iters<=1` 直接单趟 `_evaluate_span`，跳过 `prev = _slots.duplicate()` 与数组比较；`buildSignalChanged` / `evaluate()` 均从段元数据读取 `iters`。
- **主路径开关**：`useIR` 默认改为 `true`。此前默认 `false`，导致 IR 编译器（连同本节的拓扑排序优化）在游戏运行时从未被调用，实测帧率无变化——优化必须与开关切换同时生效才有意义。

### 收益口径

单个事件/时钟拍对一段电路的求值次数由 `≤64` 次降为 `1` 次；表达式树 pull（`SwCommon.EvalStruct`）调用在 `useIR=true` 下恒为 0（`test_ir_tick_bypasses_evalstruct`）。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `ir_parity_test`（含 tree-vs-IR 双跑对拍，`useIR` 默认已开） | PASS：6 tests / 862 asserts / 13.2s，加法器 + 计数器存档逐拍零差异 |
| `test_circuit_led` + `test_ir_out_slots` | PASS：2 tests / 852 asserts |

`test_ir_out_slots` 的 Fix-4A 语义随之调整：用例内先显式 `useIR=false` 再加载存档以验证「关闭时不编译」，同时新增断言校验默认值为 `true`。

---

## 改造二·续：T2.7 变化驱动的事件路径

### 动机（4 个 8 位计数器实测 15 帧的分析器数据）

`useIR` 打开后，`SWBoolProgram.evaluate_range` 只占 **1.98ms/4 次**，但 `buildSignalChanged` 仍要 35.93ms——时间全花在「把整条下游闭包重跑一遍」上：

| 热点 | 每帧调用数 | 说明 |
|------|-----------|------|
| `_pushDriverNets` | 18.86ms / 4 次 | 遍历闭包内每个建筑的每个引脚 net，无条件写回并刷电线 |
| `reCalSignals`（Pass B） | ~13ms / 756 次 | BFS 闭包里每个 LED/非门/寄存器都重跑，即使它的 slot 值没变 |
| `isRenderPartsDirty` | 9176 次 | 正比于 `notifyPosArr` 长度（闭包大小），不是正比于真正变化的建筑数 |
| `SWBuildWire.setValue` / `getCircuitCompoent` | 8584 次 | 电平没变的 net 上的电线也被重复 setValue |

### 架构变更

- **求值期记录变化集**：`SWBoolProgram._evaluate_span` 每条写 `_slots[d]` 的指令先比较旧值，变化才写入并把 slot 记入 `changed_slots`；`OP_OUT` 在 `net.curSignal` 真被改写时把该 net 记入 `dirty_nets`。
- **slot → 归属建筑反查表**：编译器登记 `slotMap` 的同时调 `_prog.add_slot_owner(src_slot, build)`（一个 slot 可多归属，用数组）。
- **Pass B 改为变化驱动**：`SWCircuitControl._collect_changed_builds()` 由 `changed_slots` 反查建筑，类型口径与原 BFS 过滤一致（LED / 1bit 寄存器 / 非门），并排除事件源自身。
- **push 改为 net 驱动**：`_pushDirtyNets(dirty_nets)` 直接遍历电平变化的 net（入口不能是「候选建筑的引脚 net」，否则驱动者被类型过滤挡掉时其电线会漏刷新）；单 net 写回逻辑抽成 `_applyNetDriver()`，编译后的全量传播 `_pushDriverNets(builds)` 仍走原路径（首次必须无条件刷）。
- **signalTex 上色同步收窄**：`_paintNet()` 只处理 `dirty_nets` ∪ 候选建筑的引脚 net（树模式保持整条闭包）。

### 语义等价性依据

IR 段求值已在 Pass B 之前把全部 slot 收敛到终值（T2.6 拓扑序单趟），因此「本拍值未变化的建筑重跑 reCalSignals」只可能得到与上一拍相同的 `signal_state`，跳过它不改变可观测状态。寄存器的边沿检测只依赖自身 `curClk/curD` 采样，跳过无变化的拍与旧行为一致。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `ir_parity_test` + `test_circuit_led` + `test_ir_out_slots` | PASS：6 tests / 862 asserts / **10.6s**（T2.6 时 13.2s），加法器与计数器存档逐拍双跑仍零差异 |
| `verilog_parity_test` | PASS：3 tests / 868 asserts |

### 剩余瓶颈（下一步）

事件路径收窄后，剩余耗时集中在渲染侧重建：任一非门/LED 换贴图就把整个 chunk 走 `drawMap` → 工作线程重填块内所有建筑的实例缓冲（`_buildRenderParts` 53 次、`getRenderParts` 724 次）。方向是**按建筑增量补丁实例**：为 chunk 记录 `build → [起始实例号, 数量]`，视觉变化时只覆写该建筑那几行 float，不再整块重算。（已由 R3.1 落地，见下）

---

## 改造三：R3.1 按建筑增量补丁实例行

### 动机（16 个计数器实测 10 帧的分析器数据）

| 热点 | 耗时/调用数 | 说明 |
|------|------------|------|
| `getRenderParts` | 241.23ms / 6601 次 | 一个非门换贴图 → 整块所有建筑都重取部件 |
| `_buildRenderParts` | 232.30ms / 442 次 | 真正失效的缓存重算 |
| `_get_instance_color` | 69.30ms / 6602 次 | 填充循环里的常数开销（ByContent 分支恒不成立却仍走函数调用） |
| `GetWireColor` | 18.52ms / 1053 次 | 每次调用新建两个 Color 的数组 |
| `getComponent` / `get_style_id` | 4.65ms / 6603、4.20ms / 1880 | 同上，正比于整块建筑数 |
| `evaluate_range` | 12.14ms / 16 次 | 电路侧已不是瓶颈（对比渲染侧 240ms 量级） |

### 架构变更

- **实例区间登记表**：`SWMultiMeshInstance2D` 在整块填充时记 `_instRanges[build] = [起始实例号, 部件数]`，并记 `_lastShowCount` 与登记时的缓冲代次 `_rangesBufferIndex`。
- **补丁下发链**：`SWBuildLayer._refreshDirtyBuildChunks` 按 chunk 分组脏建筑 → `SWDrawManager.updataChunks(chunkPosArr, patchMap)` → `_refreshChunkContent(chunkPos, patchBuilds)` → `drawMap(mapData, false, patchBuilds)`。
- **工作线程分支**：`calBuffer` 的 ByContent 分支先问 `_can_patch()`；命中则只对补丁建筑调 `getRenderParts()` + `_write_parts()` 覆写各自实例行，`showCount` 沿用 `_lastShowCount`；未命中退回整块重填并重新登记区间。
- **保守退回条件**（计入 `s_patch_bail` 原因）：非 ByContent / 无补丁建筑 / 无区间记录 / 上次填充为空 / 缓冲代次不符 / 补丁建筑没有区间（新增或 chunk 内容变过）/ 实例容量溢出 / 部件数变化。
- **代次失效点前移**：`drawMap` 收到整块重填请求时立即置 `_rangesBufferIndex = -1`。工作线程可能把「整块重填 + 后续补丁」两次 post 合并处理（semaphore 计数 >1 时数据以后者为准），旧代次记录会让补丁退回整块重填，而不是写到一块从未填充的 buffer 上。
- **实例池复用**：`reUse()` 清空 `_instRanges` / `_pendingPatchBuilds` / `_lastShowCount` / `_rangesBufferIndex`。
- **常数开销清理**：`_get_instance_color` 在填充循环内内联为 `buildState.mask_color`；`SWStyleTexture` 的 rect→styleId 键从 `"x,y,w,h"` 字符串改为规范化 `Rect2`（去掉每次调用 `"%d,%d,%d,%d" %` 的格式化）；`SwCommon.GetWireColor` 按 wireName 缓存复用返回数组。

### 静态计数器

| 计数器 | 位置 | 说明 |
|--------|------|------|
| `SWMultiMeshInstance2D.s_patch_hit_count` | `render/sw_multi_mesh_instance_2d.gd` | 增量补丁分支被命中的次数 |
| `SWMultiMeshInstance2D.s_full_refill_count` | 同上 | ByContent 整块重填次数 |
| `SWMultiMeshInstance2D.s_patch_bail` | 同上 | `Dictionary<原因, 次数>`：补丁退回整块重填的原因分布 |

### 验收结果（GUT headless）

新增 `test/render/test_r31_patch.gd::test_render_patch_matches_full_refill`，口径是**补丁产物必须与整块重填逐浮点一致**：

1. 加载 `计数器2` 存档 → 把视口对准「事件会标脏」的 chunk → 断言发生整块填充（区间登记完成）；
2. 连续按/松开关驱动 `_refreshDirtyBuildChunks` → 断言 `s_patch_hit_count` 增加（补丁路径真的被走到，不是全程退回重填）；
3. 快照各区块 `multimesh.get_buffer()` → 调 `flush_and_update_chunks` 强制整块重填 → 再快照，断言可见实例数相同且逐浮点首个差异下标为 -1。

| 用例 | 结果 |
|------|------|
| `ir_parity_test` + `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：7 tests / 872 asserts / 13.5s |
| `verilog_parity_test` | PASS：4 tests / 878 asserts / 2.7s |

### 测试事件源的选择口径（踩过的坑）

`计数器2` 存档手动打拍（`clock.onPressed(true)` 反复翻转）**不会改变任何 LED/非门/寄存器的外观**：IR 与树两条后端的 `isRenderPartsDirty()` 计数同为 0（电线 HIGH 数会变，说明信号确实传播，只是该存档的寄存器在本驱动序列下不产生可见边沿）。因此渲染侧验收必须用**开关**作为事件源——按下/松开必然切换开关自身贴图并连带下游非门/灯泡换贴图。

## 改造三·续：R3.2 换贴图原地补丁 + T2.8 拍内合并 push

### 动机（R3.1 落地后的分析器数据，16 个 8 位计数器）

R3.1 把「一个建筑换贴图 → 整块重填」收窄成「只覆写该建筑的实例行」，`getRenderParts` 调用数从 6601 掉到 1429，但时间没跟上：

| 热点 | 单帧耗时/调用数 | 说明 |
|------|----------------|------|
| `_buildRenderParts` | 533.32ms / 789 次 | 换贴图只是 body part 的 rect 变了，却重建整份 parts（引脚+底座+主体，每 part 一个 8 键字典） |
| `_can_patch` | 430.44ms / 122 次 | 内含第一次 `getRenderParts()`，脏建筑的整份重建实际发生在这一行 |
| `buildSignalChanged` | 64.01ms / 16 次 | 16 个时钟各跑一次，下游 net 高度重叠 |
| `_pushDirtyNets` + `_applyNetDriver` | 26.47 + 26.04ms / 719 次 | 同一 net 一帧内被解析驱动者、刷电线多达十几次 |
| `SWBuildWire.setValue` / `getCircuitCompoent` | 5.76 + 2.99ms / 1430 次 | 电线 `signal_state` 反复重写 |

### R3.2：把「换贴图」从结构性失效里拆出来

- `SWBuildCompoentRenderable` 新增 `_bodyRectDirty` 与 body part 区间（`_buildRenderParts` 记录 `_bodyPartsStart/_bodyPartsCount`）。`getRenderParts()` 在无结构性脏、只有 bodyRect 脏时走 `_applyBodyRect()`：只复制指针数组 + 为主体 part 新建字典，引脚/底座部件原样复用。
- LED / 非门 / 1bit 寄存器 / 按钮的 `buildStateChanged` 改调 `markBodyRectDirty()`（原来是 `markRenderPartsDirty()`）。
- **线程安全口径**：已发布的 parts 数组及其部件字典一律视为只读——工作线程可能正拿着上一份快照填 buffer。因此视觉补丁用 copy-on-write，绝不原地改已发布的字典。
- 结构性失效的入口补齐：`in_loop` 改为带 setter 的属性（翻转即整份重建，环路红是烘进引脚/底座颜色的），`resetBuildState()`（重编译会换引脚 net、重置 drawRect）也标结构脏。
- `SWBuildLayer._refreshDirtyBuildChunks` 去掉收集后再次 `markRenderPartsDirty()` 的那行：它会把刚登记的视觉补丁升级成整份重建，且标记本就由 `getRenderParts()` 消费时清除。

### T2.8：一拍内的 push/上色合并

- `SWCircuitControl.beginTick()/endTick()`：`SWBuildLayer._process` 的时钟分支把整拍 16 个事件包起来。
- **push 不能延后**：`_applyNetDriver` 写回的 `net.curSignal` 是同拍后续事件 `OP_INPUT` 的输入，必须逐事件写。能延后的只有两个纯输出：电线 `signal_state` 写回与 signalTex 上色（纹理每帧只 flush 一次，拍内中间翻转本来就不成像）。
- `_queueNetVisual()` 按 net 去重登记，`endTick` 统一执行；`_paintVisuals()` 同理把「电平变化 net ∪ 候选建筑引脚 net」合并成一次带 `updated_nets` 去重的上色。
- `_pushDirtyNets` 里给单驱 net 开快速通道：`OP_OUT` 已把同一 slot 值写进 `curSignal`，无需再回溯 `slotMap`，直接登记电线。多驱（wired-AND 末位胜）仍逐次解析。
- **写序不变量（踩过的坑）**：同一条电线会同时出现在多条 net 的 `wireGroup.wireBuilds` 里（`计数器2` 存档实测 84 条，交叉电线 WIRE_BRIDGE 的两组都把它算进去），电线只有一个 `signal_state` 字段，谁最后写谁胜。合并到拍尾时若按「首次出现」排序就会与逐事件顺序不一致（实测奇数拍出现 30+ 条电线终值不同）。因此 `_tickNetSignals` 采用 `erase + 重新赋值`，使应用顺序等于「最后一次触碰」的顺序，与逐事件完全同序。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `ir_parity_test`（新增 tick-batch 对拍）+ `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：默认 3 tests / 862 asserts；IR 对拍 8 tests / 878 asserts / 16.3s |
| `verilog_parity_test` | PASS：4 tests / 878 asserts / 2.7s |

新增用例 `test_parity_tick_batch_matches_per_event`：同一存档、同一事件序列，A 轮逐事件 push、B 轮整拍 `beginTick/endTick` 合并 push，逐拍快照（全部非争议建筑 `signal_state` + 寄存器 `qState` + 单驱 net `curSignal`）零差异——这条用例正是上面那个写序不变量的守门人。

### 剩余瓶颈（下一步）

- 工作线程侧：`_can_patch` 仍要为每个待补丁建筑取一次 parts；主体 part 已免重建，引脚 part 的字典分配在结构性重建时仍是 8 键/个。方向是把 part 从 `Dictionary` 换成扁平 `PackedInt32Array`/结构体数组，或让 body 的 style_id 直接由 `net_id` 同类的 custom 通道下发。
- 主线程侧：Pass B 的 `reCalSignals` 与 `_collect_changed_builds` 仍按事件跑（时序语义要求），`evaluate_range` 已是查表级开销。
- 每个 chunk 实例各持有一个 `Thread`，视口内区块多时线程之间抢 CPU；方向是收敛成固定大小线程池 + 按 chunk 排队。

## 改造三·续二：R3.3 主体 style 单浮点覆写

### 动机（R3.2 + T2.8 之后的分析器数据，16 个 8 位计数器）

主线程基本清空了：`SWBuildLayer._process` 从 106.03ms 掉到 **0.43ms**，`buildSignalChanged` 64.01 → 7.19ms，`_buildRenderParts` 从每帧 789 次直接归零（换贴图不再重建整份部件）。Script Functions 总量 505.33 → 100.56ms，剩下的都在**区块工作线程**上：

| 热点 | 单帧耗时/调用数 | 说明 |
|------|----------------|------|
| `_applyBodyRect` | 16.17ms / 682 次 | R3.2 的 copy-on-write：复制指针数组 + 新建主体字典 |
| `_write_parts` | 11.00ms / 682 次 | 补丁仍重写该建筑**全部**实例行（Transform2D + 颜色 + 4 个 custom 浮点） |
| `getRenderParts` | 0.49ms / 1364 次 | 每个补丁建筑每帧被取两次：`_can_patch` 比大小一次、写缓冲一次 |
| `_can_patch` | 3.38ms / 100 次 | 100 个区块各一次 |
| `isRenderPartsDirty` | 2.13 + 1.76ms / 1124 次 | 事件通知列表里同一建筑反复出现 |

### 架构变更

- **parts 快照改在主线程下发**：`SWBuildLayer._refreshDirtyBuildChunks` 对每个脏建筑取一次 `getRenderParts()`，`patchMap[chunk]` 的元素由 `建筑` 变成 `[建筑, parts 快照]`；`_can_patch` 与 `calBuffer` 只读快照，不再从工作线程回调建筑组件。收益是三份的：省掉每建筑每帧一次的重复取用、把 copy-on-write 的分配挪回主线程、消除「主线程改字典 vs 工作线程读字典」的跨线程竞态。
- **style-only 快速通道**：`SWBuildCompoentRenderable` 记录最近一次快照是否只是主体 style 变了（`_lastSnapshotStyleOnly`，由 `_applyBodyRect` 置真、`_buildRenderParts` 置假）。若是，工作线程只把主体那几行的 **style 浮点**（`use_colors` 时实例行第 12 个 float，否则第 8 个）覆写为新值，引脚/底座行的 transform 与颜色沿用上帧缓冲。
- **为什么可以只写一个浮点**：`_can_patch` 已经校验 `_pingPongIndex == _rangesBufferIndex`（区间登记时的缓冲代次与当前一致），而这些实例行自上次整块重填以来只被同一个工作线程写过——除 style 外没有别的字节会变。掩码色变化只发生在放置/选中路径，那条路总是整块重填，会先把代次标记作废。
- 新增计数器 `SWMultiMeshInstance2D.s_patch_style_only_count`。

### 验收结果（GUT headless）

`test/render/test_r31_patch.gd` 增加一条断言：换贴图事件必须命中 style-only 快速通道（否则后面的逐浮点一致就只是整行重写的自证）。补丁产物与整块重填仍逐浮点一致。

| 用例 | 结果 |
|------|------|
| `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：3 tests / 863 asserts / 2.5s |
| `ir_parity_test`（含 tick-batch 对拍） | PASS：8 tests / 879 asserts / 18.1s |
| `verilog_parity_test` | PASS：4 tests / 879 asserts / 2.8s |

### 剩余瓶颈（下一步）

- 每帧仍有 100 个区块各跑一次 `drawMap → 工作线程 → bufferCalFinish → multimesh.set_buffer()`，即使块内只有 7 个建筑变化，也要把整块 `PackedFloat32Array` 重新上传一次 GPU。方向：把 custom 通道（style/net/flags）拆成独立的局部上传，或让 `set_buffer` 只提交脏区间。
- 每个 chunk 实例各持有一个 `Thread`，视口内区块多时线程之间抢 CPU。方向：固定大小线程池 + 按 chunk 排队。
- 事件通知列表在 `_refreshDirtyBuildChunks` 里已按建筑去重（`changedBuilds` 字典），所以 `isRenderPartsDirty` 的 1124 次是真实的变化建筑数，省不掉；能做的是让每个建筑每帧的代价更低（见 R3.4）。

## 改造三·续三：R3.4 换贴图补丁零分配

### 动机

R3.3 把 parts 快照取用挪回主线程之后，`_applyBodyRect` 的 copy-on-write 也跟着上了主线程——每帧 682 次、16.17ms 自耗时（约占 120 帧预算的 1/5），而它只是把一个整数写进几个浮点位置。同时工作线程还残留 `pb.getRenderableCompoent()` 与 `comp.isSnapshotStyleOnly()` 两处跨线程回调。

### 架构变更

- **补丁条目自解释**：`[建筑, parts 快照, style 补丁]` 三元组，两者互斥。只换主体贴图时主线程只算一次 `get_style_id`，下发 `[style_id, bodyStart, bodyCount]`，**不复制 parts 数组、不新建部件字典**；结构变化才下发快照。工作线程不再触碰任何建筑组件。
- **缓存延迟纠正**：`getStylePatch()` 下发后置 `_bodyStylePending` 而不清 style 旧值；`getRenderParts()` 见到该标记才执行 `_applyBodyRect`。于是 copy-on-write 只在真正发生整块重填时付一次，且重填读到的永远是当前 `drawRect`。
- `_bodyRectDirty` 在补丁下发时即清除，同一建筑不会因“待补”状态每帧重复进脏列表；`markRenderPartsDirty()`（旋转/环路/重置）同时清两个标记，语义与 R3.3 一致。
- 新增退回原因 `style_patch_out_of_range`；删除 `isSnapshotStyleOnly()` 与 `_lastSnapshotStyleOnly`。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：3 tests / 863 asserts / 2.5s |
| `ir_parity_test`（含 tick-batch 对拍） | PASS：8 tests / 879 asserts / 17.4s |
| `verilog_parity_test` | PASS：4 tests / 879 asserts / 2.8s |

`test_r31_patch` 仍逐浮点比对「补丁产物 vs 整块重填产物」，因此延迟纠正路径（先下发 style 补丁、再整块重填）的正确性由该用例兜住。

## 改造四：R4.1 删掉电线 signal_state 的逐帧写回

### 动机（R3.4 之后的分析器数据，16 个 8 位计数器，实测 25 帧 / Process 106.89ms）

渲染侧已经不在榜上（`_applyBodyRect`、`_write_parts`、`getRenderParts` 全部消失），剩下的三大块都在主线程：

| 热点 | 耗时/调用数 | 说明 |
|------|------------|------|
| `SWCircuitControl.endTick` | 32.92ms / 1 | 其中 `_applyWireSignals` 26.57ms / 684、`_paintVisuals` 5.52ms |
| `SWBuildLayer._refreshDirtyBuildChunks` | 31.89ms / 1 | 其中 `isRenderPartsDirty` 9.50ms / 1379 |
| `SWCircuitControl.buildSignalChanged` | 33.18ms / 16 | IR 段求值 8.03ms、各类 `reCalSignals` ≈15ms |

`_applyWireSignals` 每拍把 684 个变化 net 的 `wireGroup.wireBuilds` 逐个 `setValue`，只为维护电线的 `signal_state` 字段。全工程 grep 确认：**没有任何逻辑读它**——求值读 `net.curSignal`，电线显示颜色由 `signalTex` 按 `net_id` 在 GPU 侧上色，剩下的读者只有存档和「建筑信息」调试面板。同理，`reCalSignals` 把输入 net 的全部电线建筑塞进通知列表，也只是为了让这条写回链跑到；这些电线在 `_refreshDirtyBuildChunks` 里必然被 `isRenderPartsDirty()` 挡掉（电线几何只随拓扑变化，拓扑变化由编辑路径标脏），1379 次检查里大半是空转。

### 架构变更

- 删除 `_applyWireSignals` / `_queueNetVisual` / `_tickNetSignals`：拍尾只剩 signalTex 上色。顺带消掉 T2.8 为「电线末位写回者胜」引入的写入次序约束——不再有共享字段要按触碰顺序定胜负。
- `_pushDirtyNets` 只对多驱（wired-AND 争议）net 做 slot 回溯写回；单驱 net 的 `curSignal` 已由本次 OP_OUT 写好，无需二次解析。
- **显示电平改为现取**：`SWBuildItemDefine.getDisplaySignal()` 对电线走 `SWBuildCompoentCircuit.getWireLevel()`（电线返回 `net.curSignal`，交叉电线固定取 `v_net`，基类返回 -1 表示回落到 `signal_state`）。存档与调试面板都改用它；树模型（`useIR=false`）里 gate `getValue` 仍会写电线 `signal_state`，但那不再是任何显示口径的来源。
- `SWBuildCompoentCircuit.reCalSignals()` 只返回 `[buildRef]`，不再展开 `net.wireGroup.wireBuilds`。
- 对拍快照的 B token 由 `signal_state` 改为 `getDisplaySignal()`，`circuit_test_harness.get_signal_state()` 同步——电线电平改由 net 派生后，两轮比较的仍是同一份功能真相。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：3 tests / 863 asserts / 2.5s |
| `ir_parity_test`（含树 vs IR、tick-batch 对拍） | PASS：8 tests / 879 asserts / 18.5s |
| `verilog_parity_test` | PASS：4 tests / 879 asserts / 2.9s |

### 剩余瓶颈（下一步）

- `buildSignalChanged` 里 `reCalSignals` 仍占 ≈15ms：IR 模式下 LED/寄存器/非门的 `reCalSignals` 其实只需要「读 slot → 换贴图」，不该再走一遍求值入口。
- `_refreshDirtyBuildChunks` 每个脏建筑新建 3 个临时数组作为补丁条目（每帧约 2700 次分配）。方向：按 chunk 下发扁平的 `PackedInt32Array` 行描述（主线程查 `_instRanges` 需先把它变成主线程可见的发布副本）。
- 每帧 129 个区块各跑一次 `set_buffer` 整块上传；每个 chunk 实例各持有一个 `Thread`。



## 改造五：Phase 2 变更定向求值（use 表 + 拓扑序工作列表）

### 动机（R4.1 之后的分析器数据，16 个 8 位计数器，实测 95 帧 / Process 47.52ms）

电线写回链删掉之后，榜首整段回到事件路径：

| 热点 | 耗时/调用数 | 说明 |
|------|------------|------|
| `SWCircuitControl.buildSignalChanged` | 27.12ms / 16 | 每次时钟事件一条 |
| └ `evaluate_range`（整段重跑） | 8.05ms / 16 | 16 个计数器 = 16 次全段扫描 |
| └ 各类 `reCalSignals` | ≈5.6ms | Pass A BFS 展开的下游规模 |
| `_paintNet` | 2.21ms / 2652 | signalTex 上色，已按需 |

语义问题：一个时钟脉冲只驱动它所在的电路段，而 IR 路径每个事件都把**整段指令重跑一遍**，再用 Pass A 的 `noticeMap` BFS 找出「可能受影响的下游建筑」逐个 `reCalSignals`。事件的真实影响面（计数器里是一个寄存器到 LED 的一小片逻辑）与工作量（整段几百条指令）完全脱钩。

### 架构变更

- **三张索引表**（`SWBoolProgram.build_indices()`，编译器 `compile()` 末尾一次性建立，幂等可重建）：
  - `slot_uses[slot] → Array[指令下标]`（升序）：谁消费这个 slot；
  - `leaf_insts[build.id] → Array[指令下标]`：该建筑的 `OP_READ`/`OP_LATCH` 状态驱动叶，即事件种子；
  - `_net_input_insts[net] → Array[指令下标]`：谁 `OP_INPUT` 读这个 net。
- **变化定向传播**：`evaluate_from(seeds)` 用小顶堆按指令下标弹出。弹出序 = 编译器拓扑发射序 ⇒ 任一指令求值时其输入已定值，**一次事件内每条指令至多执行一次**（无需迭代、无需 visited 集合）。只有 `dst` 值真的变了才 `_propagate`，`OP_OUT` 只在 `net.curSignal` 真变化时才把下游 `OP_INPUT` 入队——变化在第一个不翻转的门处自然停止。
- **`_eval_inst(i, propagate)` 抽出共用**：整段路径 `_evaluate_span` 按线性扫 propagate=false，变更定向 propagate=true，两条路径求值语义同源，不存在第二份实现。
- **`useChangeDirected` 单开关回退**（默认 true）：`buildSignalChanged` 头部走快路径（跳过 Pass A BFS），关掉即完全回到「整段重跑 + BFS」旧路径；旧路径与 `useIR=false` 树路径都仍在对拍覆盖内。
- **安全阀**：`_cyclic_inst` 标记 `iters>1`（Kosaraju 检出组合环）段内的指令，一旦传播碰到就 `_hit_cyclic` → 清空堆退回全量 `evaluate()`；另有 `op_arr.size()+seeds` 的弹出预算兜底。种子为空同样退回旧路径。
- **`_pending_nets`**：`_applyNetDriver` 在 IR 之外改写 `net.curSignal`（wired-AND 末位胜）后登记，下一个事件的种子会补读这些 net 的 `OP_INPUT`——这是整段重跑免费送掉、变更定向必须显式补的依赖。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：3 tests / 863 asserts / 2.6s |
| `ir_parity_test`（新增 CD 对拍 + 指令数断言） | PASS：10 tests / 887 asserts / 33s |
| `verilog_parity_test` | PASS：4 tests / 879 asserts / 3.0s |

- `test_parity_change_directed_matches_full_segment`：计数器2、加法器3 两份存档，24 拍时钟 + 开关事件，`useChangeDirected` 开/关逐拍对比「全部建筑显示电平 + 全部 net curSignal + 寄存器 qState」，零差异。
- `test_change_directed_evaluates_fewer_instructions`（计数器2，8 轮 × 16 个时钟事件取平均）：

| 口径 | 整段重跑 + Pass A BFS | 变更定向 | 比值 |
|------|---------------------|---------|------|
| 每次事件执行指令数 | 499.0 | 3.0 | **省 99.4%** |
| 每次事件墙钟耗时 | 1.714ms | 0.110ms | **15.6×** |

  断言口径为 `cd/full < 0.6`（实际比值 0.006），耗时只打印不断言以免把机器噪声写进验收门。

### 剩余瓶颈（下一步）

- 指令数已降到 O(影响面)，但 GDScript 解释器仍是乘数：`_eval_inst` 的 `match` + 数组下标每次约 10 层解释开销。Phase 4 把求值循环搬到 GDExtension（C++）后，同样 72 条指令的绝对耗时还应再降一个数量级。
- `reCalSignals` 的 LED/寄存器/非门 ≈5.6ms 未动（任务 #3）。
- 每帧 129 区块 `set_buffer` 整块上传、每 chunk 一个 `Thread`、补丁条目 3 个临时数组。

## 改造六：Phase 4 求值循环搬进 GDExtension（SWBoolEval）

### 动机

Phase 2 把每次事件的指令数降到 O(影响面)，但乘数仍是 GDScript 解释器：`_eval_inst` 的 `match` + `PackedInt32Array` 下标 + `Dictionary` .has/erase，一条指令约十层解释。事件路径拆解（改造五「剩余瓶颈」）显示求值本体只占 17%，可是**退回整段收敛的最坏情况**（组合环段、种子为空、百万表达式）仍然与指令总数成正比，这一项必须换成原生。

### 架构变更

- **职责切分**：GDScript 保留编译器、段元数据、种子选择与 `SWNet`/`SWBuildItemDefine` 对象桥接；C++ 持有指令数组、slot 位图、net 电平表与两张 CSR use 列表（`slot → 消费指令`、`net → OP_INPUT 指令`）。原生侧是求值状态的**唯一 owner**，GDScript 的 `_slots` 降级为每事件按变化槽回写的镜像——重编译 `load_slots` 与「关开关回退 GDScript」都依赖它，因此镜像必须在 `_native_apply_changes()` 里同步。
- **零清理工作列表**：堆元素带代际戳（`heap_stamp[i] == heap_stamp_id` 即在堆中），每事件只自增戳记，省掉 GDScript 版 `_in_heap.clear()` 的哈希表重建；`heap_stamp_id` 触顶时整表归零重来。
- **叶子回读**：`OP_READ`/`OP_LATCH` 通过 `set_leaf_callable` 注册的 `SWBoolProgram._native_leaf_cb` 反向调用组件 `getPinReadState`，与 GDScript 路径同源，状态机真相仍在组件里。
- **net 值一致性**：原生 `OP_INPUT` 读自己的 `net_values`，不再看 `net.curSignal`。IR 之内只有 `OP_OUT` 写 net（原生自己维护）；IR 之外只有 `_applyNetDriver`（wired-AND 末位胜）会写，它已 `mark_net_dirty` 登记，`collect_seeds()` 在清空 `_pending_nets` 前把这些 net 的现值 `sync_net` 推进原生侧。
- **变化上报**：`get_changed_slots` / `get_changed_net_ids` / `get_changed_net_values` 三个 `PackedInt32Array` 回灌 `changed_slots` / `dirty_nets`，事件路径的 `_collect_changed_builds` + `_pushDirtyNets` + 上色逻辑一行未改。
- **`useNativeEval` 单开关回退**（默认 true，`SWCircuitControl` → `SWBoolProgram.set_native_eval()`）：`ClassDB.class_exists("SWBoolEval")` 失败（未编译扩展、release 模板缺 `.windows.release` 库）时置 `_native_failed`，`_native` 保持 null，全部入口自动走 GDScript；`get_slot_value` / `evaluate` / `evaluate_range` / `evaluate_from` / `begin_event` / `collect_seeds` 六个入口是唯一分派点。
- **工具链**：godot-cpp 需按本机引擎重新生成绑定（4.7.2 API dump），并修掉两处上游问题——`global_constants.hpp` 把 `<cstdint>` 的 `INT*_MIN/MAX` 当全局常量发射（既不能声明、`#undef` 又会污染后续 STL 头，生成代码对这批名字零引用，直接跳过）与 `INT64_MIN` 字面量 MSVC 不合法。构建：`cmake -S gdextension -B ../build/sw_circuit_native -G "Visual Studio 17 2022" -A x64` → `cmake --build ../build/sw_circuit_native --config Debug`（build 目录放在仓库外，多配置生成器会往里塞几百个 .obj），产物按 `.gdextension` 声明落到 `gdextension/bin/`。必须 `--config Release`：预编译的 godot-cpp 静态库虽然是 `template_debug` 名字，CRT 却是 `/MD`＋`_ITERATOR_DEBUG_LEVEL=0`（名字里的 debug 指 Godot 的 `DEBUG_ENABLED`，与 CRT 无关）；用 Debug 配置链接会报 78 个 LNK1319/RuntimeLibrary 不匹配，而且**失败链接会把 `bin/` 里已有的 dll 删掉**——本项目求值入口是「拿不到原生类就回落 GDScript」，dll 没了测试照样全绿，只是悄悄失去加速。为此 CMakeLists 把 `MSVC_RUNTIME_LIBRARY` 固定成 `MultiThreadedDLL`，对拍用例也各自断言 `_native != null`。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| `test_circuit_led` + `test_ir_out_slots` + `test_r31_patch` | PASS：3 tests / 863 asserts |
| `ir_parity_test` + `verilog_parity_test`（新增 2e 原生对拍 + 组合环趟数对拍） | PASS：5 scripts / 13 tests / 939 asserts / 57s |
| 仅 `verilog_parity_test` | PASS：4 tests / 879 asserts / 2.8s |

- `test_parity_native_matches_gdscript_eval`：计数器2、加法器3 各跑「GDScript 变更定向 vs 原生变更定向」+「GDScript 整段 vs 原生整段」（覆盖 `evaluate_all`/`evaluate_span`），逐拍对比全部建筑显示电平 + 全部 net curSignal + 寄存器 qState，零差异。
- `test_native_matches_gdscript_on_cyclic_span`：两份存档的段全是 `iters=1`（探针跑过：加法器3 1/1 段、计数器2 1/1 段都是 iters=1），存档对拍根本走不到 `iters>1` 的多趟不动点分支，故手工搭一条「三格反相环」段（每趟都在翻转、永不收敛），对 `iters=1/2/5/6` 逐一比 收敛值 / 执行指令数 / 变化槽集合。指令数必须相等，否则两侧趟数口径不同——这条断言逼出了实现修正：GDScript 的 `prev` 初值是空数组，第一趟比较恒为假，所以 `iters>1` 至少跑两趟，原生侧原来「先快照再求值」会少跑一趟，已改成同款循环。
- `test_change_directed_evaluates_fewer_instructions`（计数器2，每行 24 轮 × 16 个时钟事件 = 384 次事件取平均；轮数从 8 提到 24 是因为 8 轮下「整条事件」列的会话启动/warm-up 噪声能盖住真实差异）：

| 口径 | 每次事件指令 | 求值本体 | 整条事件 |
|------|------------|---------|---------|
| 树 pull | 0 | — | 16.137ms |
| IR 整段重跑 | 499.0 | 0.8484ms | 1.9105ms |
| IR 整段 + 原生 | 499.0 | **0.0663ms**（12.8×） | 1.1084ms |
| IR 变更定向 | 3.0 | 0.0275ms | 0.2675ms |
| IR 变更定向 + 原生 | 3.0 | **0.0078ms**（3.5×） | 0.1982ms |

  Phase 2 + Phase 4 叠起来，一次时钟事件 1.91ms → 0.198ms（**9.6×**）。CD 路径只剩 3 条指令，原生能省的绝对量已到微秒级（省 0.02ms），瓶颈转移到事件外围 glue；而「整段重跑」这条最坏路径（组合环退回、百万表达式整段收敛）的求值本体被压到 1/12.8，正是百万表达式场景要的量级。
  **订正**：本表的 3.0 条/事件是修复前的测量，「便宜」正是因为变更定向路径压根没把寄存器叶指令踢进队列——同一口径在改造七修复后为 11.0 条/事件，计数器才会真的走动。
  同口径在改造五里量到「整段 1.714ms / 变更定向 0.110ms」，与本轮的 1.91/0.267 有 ±2× 的绝对差（headless 下 GDScript 解释耗时受机器负载影响明显），所以跨章节只比同一次运行内的比值，不比绝对毫秒。
  断言口径：`nat.insts == cd.insts`（指令数必须与 GDScript 完全一致）与 `full_nat.eval_ms < full.eval_ms`（只对可稳定复现的整段路径断言，微秒级的 CD 差值不进验收门）。

### 剩余瓶颈（下一步）

- 变更定向 + 原生之后，求值只占整条事件的 3.7%；`reCalSignals`（任务 #3）与 `_collect_changed_builds`、`_pushDirtyNets`、上色才是事件路径的大头，其中 `reCalSignals` 在 IR 模式下仍是「树语义重算」，应改成「读 slot + 换贴图」薄路径。
- 每帧渲染侧未动：129 区块 `set_buffer` 整块上传、每 chunk 一个 `Thread`、补丁条目 3 个临时数组。
- 目前只发 `windows.debug` 库；导出 release 模板前需补 `.windows.release.x86_64` 配置，否则运行期自动回落 GDScript（功能正确，只是失去加速）。

---

## 改造七：计数器冻结与删除闪退回归修复

用户实测「两个 8 位计数器不跳了，删除建筑会闪退」。两条独立根因，都不在渲染侧。

### 根因与修复

- **计数器冻结**：寄存器的 Q 是状态驱动的 `OP_READ` 叶指令，`qState` 只在 IR 之外由 `reCalSignals()`（Pass B）改写；叶指令没有操作数，use 表无从把它踢进工作队列，于是时钟事件锁存完之后新的 `qState` 永远传不下去，变更定向路径每拍只求值 3 条指令便收手（就是上面被订正的那个数）。修复：编译期把每段内时序元件的叶指令登记进 `seq_leaf_insts[circuitID]`，`collect_seeds()` 在事件种子后追加**源所在段**的时序叶。播种范围限制在源所在段而非全局所有寄存器，与整段重跑路径「每事件重读本段全部叶」逐拍等价，代价仍是 O(依赖锥 + 本段寄存器数)，跨电路不会互相打拍。
- **删除建筑的两处漏账**：`_do_cut()` / `_do_delete_selected()` 没照 `onEraseDragEnded()` 的口径收尾——既不调 `updateBuildCircuit()` 重建电路，也不把被删时钟从 `clockBuildArr` 注销，于是已删除的时钟继续逐拍驱动旧电路。补上注销后立刻暴露出第二个更深的崩溃：重编译会让指令数组变短，而原生侧 `configure()` 用 `Vector::resize_zeroed()` 复位 CSR——它等价于 `CowData::resize<true>`，**只清零新增尾部**，长度不变或缩小的那部分保留上一轮的桶计数，前缀和偏大，`use_items` 写入下界越出（`FATAL: Index p_index = 1702 is out of bounds (size = 1656)`）。修复：改用 `resize_clear()`（`resize` + 全表写 `T()`），`slot_count`/`net_count` 一律从指令流重新取上界而不是信调用方传进来的旧值，`_native_setup()` 的口径取 `_slots` 镜像长度（镜像跨批次只增不减，两侧必须同源）。`slots` 仍只扩容不清零，槽值要活过重新 `configure`。
- 叶子回读加了失效守卫：失活段的 meta 仍留在表里，`_leaf_state()` 逐层校验 `is_instance_valid(build)` 与组件非空后回 0；GDScript 路径与原生回调统一走 `_leaf_state_of(slot)` 读同一份 `dst → [build, dir]` 镜像，避免两条路径取到不同形状（此前 `_eval_inst` 直接把 `latch_meta`/`read_meta` 的 Dictionary 传给形参为 `Array` 的函数，刷出满屏 SCRIPT ERROR）。

### 新增回归用例（并入默认门禁）

- `test_runtime_tick.gd`：不注入事件，让游戏自己的 `_process` 时钟循环跑 12 组采样，GDScript 变更定向 / 原生变更定向 / 原生整段 / 旧树四条路径都必须「位串至少变过两次」。先把存档里的开关全拨亮——开关全灭时加数为 0，`Q+0=Q` 保持 0 是正确行为，静止轨迹什么也证明不了。
- `test_delete_regression.gd`：走真实删除入口 `_do_delete_selected()`，删时钟与删寄存器各跑变更定向/整段两种模式，断言建筑表已摘除、时钟数 -1，删除后再空转 180 帧存活且存活那路计数器继续跳。
- `ir_parity_test.gd` 新增 `test_parity_counting_counter_matches`：`2x计数器` 开关全亮下跑 24 拍，变更定向 vs 整段 vs 原生三方逐拍对拍（LED/net/qState），并断言时钟打拍期间状态确实在变。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| 默认门禁（`test_*.gd`，新增两份回归后） | PASS：5 scripts / 11 tests / 881 asserts / 27.1s |
| `ir_parity_test`（含新增计数器对拍） | PASS：6 scripts / 21 tests / 948 asserts / 138.9s |
| 仅 `verilog_parity_test` | PASS：4 tests / 879 asserts / 4.2s |

修复后同口径重测 `test_change_directed_evaluates_fewer_instructions`（计数器2，24 轮 × 16 时钟事件）：

| 口径 | 每次事件指令 | 求值本体 | 整条事件 |
|------|------------|---------|---------|
| 树 pull | 0 | — | 12.142ms |
| IR 整段重跑 | 499.0 | 0.7203ms | 1.5951ms |
| IR 整段 + 原生 | 499.0 | **0.0545ms**（13.2×） | 0.8974ms |
| IR 变更定向 | 11.0 | 0.0526ms | 0.1982ms |
| IR 变更定向 + 原生 | 11.0 | **0.0300ms**（1.8×） | 0.1733ms |

变更定向从 3 条（不算）涨到 11 条（真在数）后仍是整段重跑的 1/45，整条事件耗时几乎没变（0.198 → 0.173ms，本轮量测噪声内）；比值口径下整段 + 原生仍有 13.2×。

---

## 改造八：存档带上元件状态

用户报「加载存档后开关全灭、计数器回到起点」。存档其实写了每个建筑的 `signal_state`，但那只是**显示快照**：求值入口读的是元件自持状态，加载时没人把它们写回去，于是首趟求值就把快照覆盖成默认电平。

- 新增 `SWBuildItemDefine.getStateData()` / `restoreStateData(data)` 一对虚函数，存进 `builds[].state` 字段；组合元件（门/电线/灯泡）无自持状态，回空字典即可。
- 三个有状态的元件各自实现：开关/按钮存 `pressed`；时钟存 `curSig`（相位不存，加载后第一拍整拍错开）；1bit 寄存器存 `qState` + `lastClk/curClk/curD`——只存 `qState` 不够，沿检测历史一丢，加载后第一次采样要么漏沿要么误锁存。
- 恢复点必须落在 `addBuild`/`updateBuildCircuit` **之前**：首趟求值就要读到恢复后的状态。
- 版本仍为 `SAVE_VERSION = 1`，`state` 字段缺失即按默认值走，老存档照旧能读（只是仍然回到起点）。

### 顺带修掉的显示滞后

`updateBuildCircuit` 里那次全量 `reCalSignals`（`createCircuit` 内）跑在 **IR 编译之前**：加载时程序已被 `resetIR` 清空，它走的是树路径，编译后的 slot 算出来没人再刷显示，于是 LED/门的显示比逻辑滞后一次重算。探针实测：存前活体 `led=…101100001…`，同状态重算并补一次 Pass B 后变成 `…110111110…`，20/80 位对不上。修复是在 `boolProgram.evaluate()` + `_pushDriverNets` 之后，对受影响的非时序元件补一次 `reCalSignals`（时序元件排除：多跑一次会重复消费在路上的那个上升沿）。这条 Pass B 与 `qState` 无关，实测对拍用例的指令数口径不变。

### 验收结果（GUT headless）

| 用例 | 结果 |
|------|------|
| 默认门禁（新增 `test_save_state`） | PASS：6 scripts / 12 tests / 891 asserts / 39.9s |
| `ir_parity_test` | PASS：7 scripts / 22 tests / 958 asserts / 167.4s |
| `verilog_parity_test` | PASS：7 scripts / 13 tests / 907 asserts / 41.7s |

`test_save_state` 把快照取在「结算过在路上的上升沿」的不动点（先跑一次与加载路径同款的 `updateBuildCircuit`），否则存前是未结算态、载后是已结算态，凭空差半拍。断言四份状态串（开关/时钟/寄存器/LED）按建筑 id 归一后逐位相等，并要求载后继续打拍仍能让 `qState` 前进——「显示对了但状态机断了」也要能抓住。

---

## 改造九：存档加载路径提速（复用按轮邻接表 + 定义资源缓存）

用户报「加载存档非常慢」。先确认不是改造八带回的：40896 建筑的存档里，本轮新增的状态恢复与补绘只占 ~30ms，8.2s 是**改造前就存在**的全量重建成本，且随建筑数线性增长。

### 三项改动

- **电线组邻接表复用**（`getWireGroupBuilds`）：BFS 每根电线都重做一遍四方向空间查询，而同一求值轮里 `find1` 已经查过；改走 `SWCircuitControl.current.getNeighborsCached()`，`control == null` 时回落原路径。
- **`resetEmptyWireNet` 复用同一份缓存**：电线四向都是端口，缓存的邻接表方向集合与「逐方向查邻格 + 判断对方端口」等价，改成位掩码判定（零分配）。
- **`SWBuildCompoentCircuitWire.getNet` 复用邻接表**：净网阶段同样逐方向查网格，改为遍历缓存邻接表；原循环 `range(3,-1,-1)` 与 `getBuildIOConnectBuildArr` 的收表顺序一致，遍历顺序逐位相同。
- **建筑定义资源按名缓存**（`SWBuildLayer.load_save_data`）：同一种建筑反复 `load("res://xxx.tres")`，40k 建筑省下几万次路径拼接与资源查找。

### 行为中立证明

`tools/repro_load_save.gd` 加了快照：加载后按建筑 id 归一，逐建筑记 `id:getDisplaySignal():in_loop`。

| 对比 | 结果 |
|------|------|
| 改动前 vs 改动后（16x计数器 + 计数器2 + 加法器，共 44471 建筑） | 463705 字节逐字节相同（`cmp` IDENTICAL） |
| 再加 `getNet` 复用后 | 仍逐字节相同 |
| 最终态 vs 基线（3 个存档） | 前 463705 字节相同，仅多出本次追加的 `38译码器` 一段 |

### 实测（headless，`load_save_data` 整段）

| 存档 | 建筑数 | 改动前 | 改动后 | 省下 |
|------|--------|--------|--------|------|
| 16x计数器 | 40896 | 8390ms | 5911 / 5996ms | −29% |
| 4x计数器 | 10224 | — | 1447ms | — |
| 计数器2 | 2556 | 715ms | 422ms | −41% |
| 加法器 | 1019 | 494ms | 188ms | −62% |
| 38译码器 | 434 | — | 101ms | — |

探针口径（`updateBuildCircuit` 内部，40896 建筑）：`find1=1314 clearState=728 nets+ids=608 resetEmptyWire=140 getCircuit=163 split+createCircuit=517 dedupe=40 loops=100 compile=199 evaluate=4 push=83 repaint=30`，合计 3956ms；改动前 `nets+ids` 是 1164ms。建壳+恢复 1869ms、刷块 142ms。

> 探针本身不是零成本：headless 下每条 `print` 走 Windows 管道实测 50~100ms，`load_save_data` 里两条就吃掉 ~200ms——小存档的绝对值要等探针摘掉后再看（上表已是摘除后的数）。

### 窗口态（真实渲染）

`16x计数器`：同步加载 5207ms，紧接着**第 1 帧 2891ms**（视口 9 个区块任务一次做完，约 320ms/区块），之后稳态 16~18ms/帧。用户感知的冻结 ≈ 5.2s + 2.9s。

### 放弃的路子：加载走「冷启动」快路径

`updateBuildCircuit` 在加载场景下 `find1` 是纯浪费（输入已经是全量建筑），跳过它能再省 1.3s。实测对拍失败：`冷==全=false`，计数器2 里 12/2556 个建筑的显示电平不同（寄存器 0 个差异），差异集中在挂在 LED 输入端、没有驱动源的悬空电线上。根因不是逻辑分歧而是**顺序**：`find1` 把结果重排成字典插入序，而悬空 net 的最终电平取决于求值顺序。已回退，留下一个语义问题待定：无驱动源的电线该显示什么。

### 验收结果（GUT headless，改动后）

| 用例 | 结果 |
|------|------|
| 默认门禁 | PASS：6 scripts / 12 tests / 891 asserts / 32.2s |
| `ir_parity_test` + `verilog_parity_test` | PASS：23 tests / 974 asserts / 132.6s |

### 剩余开销排序（16x计数器）

1. 视口首帧区块几何重建 2.9s（与正常平移同一条路径，密集建筑下单区块 ~320ms）
2. `find1` 1.3s（加载场景可省，但要先解决悬空 net 的顺序语义）
3. 建壳+恢复 1.87s（每建筑 ~45µs：`CreateCompoent` 无池化，建筑 + 状态 + 组件各一次 `new()`）
4. `clearState` 728ms、`split+createCircuit` 517ms
