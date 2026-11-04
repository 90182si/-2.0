# SPEC-06 · GDExtension 原生求值（已实现、已验证、**暂未启用**）

> 承接 SPEC-05。本文记录把 `evaluate()` 下沉到 GDExtension 的完整过程：
> 做到了什么、实测数据、以及为什么最终**没有在主流程启用**。

---

## 0. 一句话结论

原生求值器**功能正确、快 8.7 倍**，但存在**约 40% 概率的偶发段错误**，未能定位根因。
因此 `SWExprBuilder.enable_native` 默认 `false`，主流程继续用已验证的 GDScript 版。
代码、构建脚本、对拍测试全部保留，修复后改一个开关即可启用。

---

## 1. 交付物

| 文件 | 内容 |
|---|---|
| `gdext/src/sw_expr_eval.h/.cpp` | 求值器类 `SWExprEval`（按 op 分段的紧凑循环） |
| `gdext/src/register_types.cpp` | 扩展入口 `sw_expr_eval_library_init` |
| `gdext/SConstruct` | SCons 构建脚本 |
| `gdext/build.ps1` | 一键构建（自动找 vcvars64） |
| `gdext/sw_expr_eval.gdextension` | Godot 扩展清单 |
| `gdext/bin/windows/template_debug/sw_expr_eval.dll` | 已构建产物（345KB） |
| `circuit/sw_expr_program.gd` | `attach_native()` / `tick()` 原生分支 |
| `circuit/sw_expr_builder.gd` | `enable_native` 开关（**默认 false**） |
| `test/circuit/test_gdext_smoke.gd` | 最小验证（不跑高频循环） |
| `tools/gdext_diag/*` | 诊断工具（对拍/压力/复现器），**不在 GUT 扫描范围内** |

### 构建方式

```powershell
pwsh -File gdext/build.ps1
```

依赖：Python3 + scons、VS2022、godot-cpp（默认 `J:/godot/godot-cpp-47`）。

---

## 2. 实测数据

### 2.1 正确性（`tools/gdext_diag/test_native_parity.gd`）

原生 vs GDScript 逐拍逐 slot 对比，5 个真实存档**全部零差异**：

| 存档 | 电路数 | 原生命中 | 差异 |
|---|---|---|---|
| 加法器3 | 1 | 1 | **0** |
| 16x计数器 | 17 | 17 | **0** |
| 计数器2 | 18 | 18 | **0** |
| 64x寄存器 | 82 | 82 | **0** |
| 测试寄存器 | 91 | 91 | **0** |

### 2.2 性能（`tools/gdext_diag/test_native_ab.gd`，同进程交替 5 轮）

```
round0: 原生=0.285 ms  GDScript=2.397 ms  加速=8.4x
round1: 原生=0.288 ms  GDScript=2.446 ms  加速=8.5x
round2: 原生=0.255 ms  GDScript=2.376 ms  加速=9.3x
round3: 原生=0.275 ms  GDScript=2.392 ms  加速=8.7x
round4: 原生=0.263 ms  GDScript=2.390 ms  加速=9.1x
中位:   原生=0.275 ms  GDScript=2.392 ms  加速=8.7x
```

（64x 存档，64 电路，22144 个表达式，每拍。）

---

## 3. 实现要点

### 3.1 数据布局

C++ 侧与 GDScript 侧逐字段对应，`upload()` 一次性灌入：

```
seg_op / seg_start / seg_count  ：按 op 分段
seg_dst / seg_src0 / seg_src1   ：目标与操作数（vals 直接下标）
seg_n / seg_off / seg_const     ：AND 多输入信息 / CONST 值
src_flat                        ：AND 3+ 输入的操作数表
extra_start / extra_dst / primary：同一表达式服务多 slot 时的补写
```

### 3.2 值缓冲用 `std::vector`

不用 `PackedInt32Array` 做内部缓冲：它的底层缓冲会在赋值/写时复制时迁移，
`ptrw()` 拿到的指针下次调用就可能悬空。`std::vector` 生命周期由本对象完全掌控。

### 3.3 边界检查

主循环对所有下标做边界检查，宁可少算一个 slot 也不越界。
（这是防御性措施，不能替代根因修复。）

---

## 4. 未解决的问题：偶发段错误

### 4.1 现象（硬证据）

- `signal 11`，崩溃地址 `sw_expr_eval+61a7`
- **崩溃地址落在指令中间**：反汇编显示 `0x1800061A2` 是一条
  `mov qword ptr [rsp+90h],rax` 指令（长 8 字节，结束于 `0x1800061AA`），
  而 `+61a7` 正好落在它中间 —— 说明**返回地址已被破坏**，不是正常调用路径。
  → 这是**栈帧被破坏**的典型特征。
- **崩溃点在 `upload` 之后的首次 `evaluate`（循环第 0 次）**，不是高频循环中
- 最小用例（1 段、3 slot）通过；2 段 NOT+AND 结构复现

### 4.2 已尝试并排除的方案（8 种）

| # | 假设 | 改动 | 稳定性（10 次） |
|---|---|---|---|
| 1 | 引用计数生命周期 | 内部缓冲 `PackedInt32Array` → `std::vector` | 未改善 |
| 2 | `duplicate()` 读到入参悬空 | 全部入参先 duplicate 到临时变量再落成员 | 未改善 |
| 3 | `get_values()` 与内部缓冲共享 | 改独立副本 / 完全不调用 | 未改善 |
| 4 | 反复 `upload()` 破坏状态 | 单次 upload + 多次 evaluate | 仍崩 |
| 5 | 下标越界（基础） | 所有下标加边界检查 | 仍崩 |
| 6 | 14 个 packed array 形参导致栈问题 | 打包成单个 `Array` 传参 | 8/10 |
| 7 | Variant → 类型隐式转换 | 改显式 `PackedInt32Array(...)` / `static_cast` | 未改善 |
| 8 | 边界检查不完整（`seg_n`/`seg_const`/`seg_src1` 长度未校验） | 每张表单独判长度 | 3/10 |
| 9 | `const Array &` 引用形参转换路径问题 | 改按值传 `Array` | 6/10 |

**结论：所有改动只带来概率波动（3/10 ~ 8/10），没有质变。** 继续黑盒试错已无意义。

### 4.3 下一步应有的做法（未执行）

需要真正的内存调试工具，而不是继续改代码猜：

1. **`/Zi /Od` 编译 + WinDbg 附加**：拿到精确栈回溯和栈内存内容，
   看返回地址被什么值覆盖了
2. **AddressSanitizer**（VS 2022 支持 `/fsanitize=address`）：直接报出越界写的**源代码行号**，
   这是最快路径
3. **Canary 检测**：在 `SWExprEval` 每个成员函数入口/出口埋哨兵值，
   定位是哪次调用破坏了栈
4. **二分法**：把 `evaluate` 的主循环逐段注释掉，找出哪一段触发崩溃

预计投入：2~4 轮。收益：8.7 倍求值加速（64x 存档从 2.39ms → 0.28ms）。
注意：相对于全局 7.08ms/拍，这项收益约占总耗时的 30%（2.11ms → 0.25ms）。

### 4.4 备用规避方案（若不想上调试器）

1. 把 `evaluate` 改成**静态函数**，执行表作为参数传入，完全绕开成员状态
2. 每个 DAG 一个独立实例，**单次 upload 后不再变更**
3. 在 C++ 侧改用 `GDExtension` 的底层 C API 直接绑定，绕开 godot-cpp 的 `PtrToArg` 转换层
4. 放弃原生求值，把 `evaluate` 的 GDScript 循环继续做微观优化（空间有限，
   当前已到每表达式 92ns，接近解释器下限）

---

## 5. 如何重新启用

1. `pwsh -File gdext/build.ps1` 重新构建
2. 把 `circuit/sw_expr_builder.gd` 的 `enable_native` 改为 `true`
3. 跑 `tools/gdext_diag/test_native_parity.gd` 确认零差异
4. **反复运行 `tools/gdext_diag/gdext_probe.gd` 至少 20 次**确认无 `signal 11`
5. 若要上线，在 CI 里加稳定性回归

---

## 6. 当前主流程状态（收尾时的实际配置）

```
SWExprBuilder.enable_native        = false   # 原生求值未启用（见 §4）
SWCircuitControl.enable_expr_dag   = true    # 表达式 DAG（GDScript 版）
SWCircuitControl.backfill_net_signal   = true   # 回填 net（电线随信号变色）
SWCircuitControl.backfill_gate_display = true   # 刷非门（非门随输入变亮暗）
```

### 64x寄存器存档实测（64 电路 / 11392 net / 25216 gate / 22144 唯一表达式）

| 配置 | 每拍 | 说明 |
|---|---|---|
| 改造前（原始实现） | **66.6 ms** | 用户反馈「加载依旧卡」时的状态 |
| 回填扁平化 + 增量修复（SPEC-04） | 15.2 ms | net 回填/LED 扁平化 |
| 回填全关（压测档） | **7.08 ms** | + 表达式 DAG + 只回填三类元件 |

上表的 7.08 ms 对应 `backfill_* = false` 的压测档；默认档（电线/非门随电路刷新）
额外承担 net 回填与门 dirty 刷新，开销见 SPEC-04 的「回填对比」。

**压测档合计 9.4 倍加速。**

### 全量测试

30~31 通过 / 4~5 失败，失败项全部是既有环境问题
（headless 无 RenderingDevice、SIM 参考模型自身偏差），与本次改动无关。
连续多次运行无崩溃。

