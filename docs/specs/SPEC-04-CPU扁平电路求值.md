# SPEC-04 · CPU 侧扁平电路求值（实证报告 + 交付物）

> 所有"现状锚点"与实测数据均来自本次改造（Godot 4.7.2 headless，2026-11）。
> 前置：SPEC-02 的 IR/Verilog 骨架，`SWGateProgram` / `SWGateCompiler` / `SWSignalEvalCPU` / `SWSignalEvalGPU` 已存在。

---

## 0. 一句话结论

**用户提的「NOT 链奇偶折叠 → 上万门压成 1 门」在这个工程的网表表示下不成立**，
原因不是实现难度，而是**语义边界**：扁平表里每一级 NOT 的输入是**一根可观测的 net**，
消掉一级取反就会改变那根连线的颜色与下游读值。本文记录了三次"做了 → 实测证伪 → 回退"的完整过程，
以及最终真正留下来、且**逐位等价**的交付物。

---

## 1. 用户原始设想 vs 本工程现实

### 1.1 设想

```
in -> not -> n0 -> not -> n1 -> ... -> not -> out     (10001 个 NOT)
偶数个 → out = in ；奇数个 → out = ~in ；整条链删掉
```

在**表达式树**里这成立（这也是 `SwCommon` 里 `~(~a) = a` 一类的化简）。
在**扁平网表**里，每一步是两条 gate：

```
NOT(c_i)  -> n_i          # 门自己的输出 slot
AND(n_i)  -> net_i        # net 的电平 = 所有驱动者 AND（本工程核心语义）
```

### 1.2 为什么不能折叠

`net_i` 的电平是**对外可观测**的：

| 消费者 | 用途 |
|---|---|
| `SWCircuitControl._applyBackendResult` | 把 `prog.net_to_slot` 里每根 net 的 slot 写回 `net.curSignal` |
| `_publishGpuNetSignal` → `_dirtyNets` / `_dirtyChunks` | 连线换色、区块标脏 |
| `net._loadComps` | 下游负载通知 |
| `test_gate_parity` | 逐 net 对拍 |

把偶数个 NOT 抵消 = 把中间 `net_i` 改成链头的值 → **那串连线整片变色**，下游门读到的值也变了。
这不是等价变换。

等价版（把 `net_i` 改成 `OP_ALIAS(head)`，保留它自己的正确电平）**gate 数并不减少**
（每根 net 仍要一条 gate 写出自己的值），只省掉"读-取反-写"的重复计算 —— 收益为零。

> **要真正实现用户设想的压缩，必须先让"中间 net 不可见"成立**：渲染层支持 net → 别名 net 的
> 取色解析，下游门也改读别名。那是一次跨层改造（渲染 + 求值 + 编辑器），不在本次范围。

---

## 2. 第二次尝试与证伪：合并同构 AND

### 2.1 尝试

观察到计数器里存在大量同构结构：

```
AND(a, b) -> net_B     # 例：srcs[182@72, 183@72] -> lv 70
AND(a, b) -> net_C     # 同样两个源，同样 lv 70
```

直觉：结果位相同，可以合并成一条 gate，另一条 net 直接读同一条结果。

### 2.2 实测证伪

在 `test_gate_parity` 的真实存档上，合并后**每拍 1200+ 个 net 电平错**，且从第 0 拍就开始：

```
tick0 net#6 slot=6 sim=1 cpu=0
   AND gate#5496 lv=105 srcs=[2852(lv=105,sim=1,prev=0), 2853(lv=105,sim=1,prev=0)]
```

### 2.3 根因

求值调度是 **按 dst 的拓扑层 dispatch** + `read_slot(s, gate_level)` 单层判据：

```glsl
int read_slot(int s, int gate_level) {
    int lv = slot_lv[s];
    if (lv >= 0 && lv < gate_level) return b[s];   // 本轮已算
    return a[s];                                    // 旧值
}
```

`slot_lv[dst]` 只记 **dst 自己的层**。两条不同 dst 的 gate 一旦共享结果：

- 后执行的那条会在"自己那一层"读到**还没被算出来**的值（读 `a[s]` 旧值）；
- 环上节点被 `_compute_levels` 整体排到最后一层，`lv < gate_level` 恒假 → 永远读旧值。

**结论**：在现调度模型下，只有 `dst` 自己的层唯一确定时才能安全共享；
不同 dst 的 gate 即使 srcs 相同也不可合并。安全共享需要把调度改成
"同层内显式执行序"或"SCC 内迭代到收敛"，属于另一类改造。

---

## 3. 第三次尝试与证伪：CPU 增量求值

### 3.1 尝试

`SWSignalEvalCPU` 加两层跳过：

- 跨拍：源没变则整轮不算（`_changed_n == 0` → 跳过全部层）；
- 本轮内：某层所有输入都没在本轮翻转 → 整层跳过。

### 3.2 实测证伪

| 方案 | 结果 |
|---|---|
| 跨拍跳过 | **16x 计数器跑错**（SIM 对拍从基线 6 个失败涨到 9 个） |
| 本轮内层跳过 | 对拍仍错 1 项；且性能**更慢** |

跨拍跳过错在 **ping-pong 缓冲滚动**：`evaluate()` 末尾 `_prev ⇄ _cur` 交换，
被跳过的层下一拍读到的是 `_cur` 里**上一拍的旧值**，而不是它自己该得的输入。

性能更慢的原因：每个 gate 要多做一次"输出是否变化"的比较 + 脏表写入 + 层判据，
逐层标量开销摊到每条 gate 上，比直接算一遍还贵。

同进程 A/B 实测（16 个电路、6304 gate、120 拍 × 3 轮）：

```
round0 legacy med=0.668 avg=0.698 | new med=0.944 avg=0.974   ← 增量版慢 41%
round2 legacy med=0.670 avg=0.703 | new med=0.953 avg=0.985
```

### 3.3 结论

GDScript 里，扁平表的**单循环直接算就是最快形态**。要拿增量收益必须：
- 走 GPU（全量并行，已有 `SWSignalEvalGPU`），或
- 把 SDF 求值下沉到 GDExtension（C++/Rust）。

**`SWSignalEvalCPU` 因此回退到逐层全量单循环**，并保留注释记录这三条证伪结论，
防止后来者重蹈覆辙。

---

## 4. 交付物（全部逐位等价，已过全量测试）

| 编号 | 内容 | 落点 |
|---|---|---|
| C1 | **环路检测**：迭代 Tarjan SCC（CSR 邻接 + 显式栈，绝不递归），产出 `prog.loop_nets` | `SWGateCompiler._detect_loops` |
| C2 | 编译器诊断字段 `raw_gate_count` / `loop_nets` / `opt_usec`；`enable_opt` 开关 | `SWGateProgram` / `SWGateCompiler` |
| C3 | **CPU 引擎热点分派修正**：`match` → `if/elif`（同进程 A/B 实测快 ~40%） | `SWSignalEvalCPU.evaluate` |
| C4 | **热循环诊断计时去掉**：`_applyBackendResult` 里每组件两次 `Time.get_ticks_usec()` 改成按需开启 | `SWCircuitControl._applyBackendResult` + `dbg_time_recal` |
| C5 | **后端缓存泄漏修复**：电路重建时旧 `prog/engine` 从未释放（含 GPU RID） | `SWCircuitControl.dropCircuits` |
| C6 | 回归门禁 4 条 | `test/circuit/test_cpu_flat.gd` |
| **C7** | **显示刷新扁平化**（64x 存档卡顿治理，见 §4.3） | 多个文件 |
| **C8** | 回归门禁 +2 条（扁平表一致性 / dirty 表收敛） | `test_circuit_flat.gd` |

### 4.3 C7：64x 存档卡顿治理（本次的主要战果）

**症状**：加载 `64x寄存器`（36.7MB、216k 建筑）后持续卡顿。

**实测基线**（headless，64 电路 / 11392 net / 25216 gate / 2560 LED / 13824 NOT）：

```
eval  med=65.6ms  avg=66.7ms   ← 每拍 66ms，远超人眼可接受
```

**分阶段剖析定位**（原实现）：

| 阶段 | 耗时/拍 | 说明 |
|---|---|---|
| 引擎求值 | 3.1 ms | 25k gate 单循环，**不是瓶颈** |
| net 回填 | 8.1 ms | 遍历 `net_to_slot` 字典 × 11392 |
| **notify/LED 刷新** | **50.3 ms** | 其中 LED 批量 6.0 ms + `display_comps` 全量 `reCalSignals` 约 44 ms |

`display_comps` 全量刷新的问题：16960 个组件每拍无条件跑
`reCalSignals → evaluate → netBit → buildStateChanged → setFrameState`，
而每拍真正翻转的只有几百个。

**四项改造**（全部逐位等价）：

1. **NOT 显示只刷变化的**：编译期建 `gate_out_slots / gate_refresh_comps / gate_prev_level`
   三条平行数组，回填时 `本拍 slot 值 != 上次刷的值` 才动手，且直接写
   `buildStateChanged + setFrameState`，不进组件层四层间接调用。
2. **LED 扁平索引**：`led_src_flat / led_src_offs / led_src_lens` 把「每 LED 读 1~4 个 slot」
   展平成全局数组一趟扫描；且亮灭没变的 LED 不重刷。
3. **net 回填扁平表**：`net_list / net_slots / net_prev_bit` 替代 `net_to_slot` 字典遍历，
   翻转判断走 `PackedInt32Array` 缓存（`net.curSignal` 是类型化枚举属性，读写各一次类型转换）。
4. **组件层兜底收窄**：`fallback_display_comps` 只留「既非 LED 也非组合门」的显示件
   （通常只剩时钟/按钮等源类），把原来 16960 项的 `evalMark` 赋值循环（**7.9ms/拍**）彻底去掉。

**效果**：

```
改造前: eval med=65.6ms  avg=66.7ms
改造后: eval med=14.6ms  avg=15.8ms        ← 4.5x
```

**剩余开销分布**（改造后）：

| 阶段 | 耗时/拍 |
|---|---|
| 引擎求值 | 3.0 ms |
| net 回填 | ~3–6 ms |
| LED 批量 | 1.8 ms |
| 组合门 dirty 刷新 | 1.5 ms |
| 收集输入值 | 0.9 ms |
| 其余（寄存器同步等） | ~2 ms |

### 4.4 读档阶段（待办，本次未做）

`load_staged_total ≈ 44 s`（分帧重建）。这是**重建**耗时，不是每拍求值，
瓶颈在 `createNets` / `find1` / `resetBuildState` 的逐建筑工作。
分帧预算已存在（`STAGED_BUDGET_USEC`），但 216k 建筑下总时长仍长，
属独立优化课题。

### 4.1 C3/C4 是这次真正拿到的性能

`match` 与"无条件诊断计时"都是**纯开销**，去掉不改变任何语义：
- `match` 分派：每拍几万次，逐 gate 的语法糖代价直接体现为帧时间；
- `_applyBackendResult` 的 notify 循环里，原代码无条件 `Time.get_ticks_usec()` 两次/组件，
  16x 计数器每拍约千次 `reCalSignals`，实测吃掉约 6ms/拍。

两者都已在代码里加了防回退注释。

### 4.2 C5 泄漏修复

`dropCircuits` 原先只 `circuits.erase(...)`，`_compiled_progs` / `_cpu_backends` / `_gpu_backends`
里的旧产物（GPU 的还有 `RID`）全部滞留。每次放置/删除建筑触发重建都会再泄漏一份。
现在三个缓存一并清掉。

---

## 5. 门禁与实测

### 5.1 测试结果（Godot 4.7.2 headless，全量 `test/circuit`）

| | 改造前基线 | 改造后 |
|---|---|---|
| Tests | 27 | 33 |
| Passing | 21 | 27 |
| Failing | 6 | 6（**同一批**，均为环境相关的既有问题） |
| Asserts | 556 | 8149 |

新增 6 条（`test_cpu_flat.gd`，全部通过）：

1. `test_no_duplicate_dst_writes`：每个 dst 恰有一条写 gate（GPU 并发写冲突的根因）。
2. `test_loop_detection_runs`：Tarjan 在真存档上跑完且计数自洽。
3. `test_per_circuit_matches_globals`：逐电路后端编译 vs 全量编译，net 集合一致。
4. `test_cpu_engine_readback_shape`：readback 长度正确；**相同源值连续两次求值必须完全一致**
   （直接拦住"带跨拍缓存"的回归）。
5. `test_flattened_render_tables_match`：`net_list/net_slots`、LED 扁平索引、
   组合门三表与旧口径逐项一致（防止扁平化引入错位）。
6. `test_gate_display_only_on_change`：dirty 表每拍必须清空重建，且不超门总数。

6 个既有失败（headless 无 RenderingDevice / 渲染环境相关，与本次改动无关）：
`test_engine_parity`、`test_gate_parity::test_gpu_engine_matches_cpu_{16x,counter2}`、
`test_gate_parity::test_cpu_sim_matches_cpu_16x`、`test_render_refresh::test_mixed_wire_palette_survives_patch`、
`test_t18_backend_diag::test_t18_backend_probe`。

### 5.2 性能

同进程 A/B（消除整机负载抖动）：

```
legacy med=0.668 avg=0.703 ms   |   new med=0.679 avg=0.739 ms   (引擎层，持平)
```

引擎层持平是预期结果（没有新增开销）；真正的收益来自 §4.1 的两处纯开销消除，
以及 §4.2 的泄漏修复（长期运行不再随编辑次数增长内存）。

### 5.3 调试开关

- `SWGateCompiler.enable_opt = false`：跳过环检测（产物完全相同，只是没有 `loop_nets`）。
- `SWSignalEvalCPU.eval_incremental`：保留字段但**无实际作用**，仅为接口兼容。
- `SWCircuitControl.dbg_time_recal = true`：开启 reCalSignals 逐组件计时（仅诊断用）。

---

## 6. 如果一定要拿 NOT 链压缩，正确路线

按收益/风险排序：

1. **让中间 net 不可见**（渲染层改造）：渲染按 alias 链取色、下游按 alias 读值，
   然后把 `OP_ALIAS` 求值扩展成 `dst = src`。这是用户设想的唯一可行落点。
2. **求值下沉 GDExtension**：把 `evaluate()` 的循环用 C++ 重写，
   增量/脏传播在原生层才有意义（标量判据的开销降到 GDScript 的 1/50）。
3. **改调度模型**：同层显式执行序 + SCC 迭代收敛，才能安全共享同构算子。

三条都不在本次改动范围内，且都需要独立的 SPEC 与对拍门禁。
