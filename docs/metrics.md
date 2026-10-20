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

- **求值后端**：从「`getValue` 递归 pull 表达式树」切换为「查询编译后扁平 IR 的 slot 值 + push 传播」，由 `SWCircuitControl.useIR` 单开关回退（默认 `false`）。
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

