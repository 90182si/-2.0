# SPEC-05 · CPU 侧表达式 DAG 求值（用户方案落地）

> 承接 SPEC-04。所有数据来自 Godot 4.7.2 headless 实测（64x寄存器存档，64 电路 / 11392 net / 25216 gate）。

---

## 0. 用户方案与原话

> 每个元件都保存了信号链路，递归嵌套 nand 和 not，可以把这些嵌套转化为一个表达式，如：
> `ledin = a.v & b.v & c.v & d.v`，用一个 bitArray 保存这四个按钮的状态，
> 每次电路需要更新，就先扫描一遍这几个按钮，把值存到 bitArray 里面，
> 然后等 led 计算信号的时候，就不要去用函数嵌套计算电平，直接用表达式取值。
> 如果表达式比较复杂，例如重复使用到某个表达式如 `(a.v&b.v)&(a.v&b.v)`，
> 就把 `(a.v&b.v)` 作为一个中间表达式 S2。

对应实现：
- **bitArray 存源状态** → `write_sources` 写进 `PackedInt32Array`（本工程早就是这种结构）
- **表达式取值替代递归嵌套** → 原 gate 表本来就是扁平的，不是递归
- **重复子表达式提成 S2** → **本 SPEC 的核心：唯一表达式 DAG + 拓扑序求值**

---

## 1. 为什么原 gate 表不能直接合并

原调度是「按拓扑层 dispatch」：

```glsl
int read_slot(int s, int gate_level) {
    int lv = slot_lv[s];
    if (lv >= 0 && lv < gate_level) return b[s];   // 本轮已算
    return a[s];                                    // 旧值
}
```

**层内 gate 之间没有执行顺序保证。** 把同层的两个相同表达式合并、让后者复用前者结果，
后执行的那个会读到上一拍的残留值。

实测（在真实存档上直接做同层 CSE）：

| 存档 | 一致合并数 | 求值差异 |
|---|---|---|
| 加法器3 | 30 | 552 处 |
| 16x计数器 | 798 | 10711 处 |
| 64x寄存器 | 3918 | 52502 处 |

因此 **CSE 必须在显式拓扑序下才安全**。

---

## 2. 交付物

| 文件 | 内容 |
|---|---|
| `circuit/sw_expr_program.gd` | 表达式 DAG 的运行时表示 + `tick()` 求值 |
| `circuit/sw_expr_builder.gd` | `SWGateProgram` → 唯一表达式 DAG + 拓扑序 + 分段执行表 |
| `SWCircuitControl.enable_expr_dag` | 开关（默认 true），false 时退回原 gate 表 |
| `test/circuit/test_expr_parity.gd` | 逐拍逐 net 对拍门禁（5 个存档全零差异） |
| `test/circuit/test_dag_ab.gd` | 同进程交替 A/B 性能基准 |

### 2.1 数据结构

```
vals[]            ：值空间 = 原 slot 数（不含额外表达式槽）
ops[]             ：表达式运算类型（NOT / AND / CONST / ALIAS）
src_flat/offs/lens：表达式的操作数（vals 的直接下标）
primary[i]        ：表达式 i 的结果写进哪个原 slot
order[]           ：拓扑序
extra_start/dst   ：同一表达式服务多个 slot 时，主目标之外的补写表
```

关键设计：**表达式结果直接写进它服务的第一个原 slot**，
不引入「表达式槽 → 散播」两跳，热循环体只剩「读 1~2 次 → 算 → 写 1 次」。

### 2.2 分段执行表

拓扑序被切成「同 op 连续段」，每段一条 `for range` 紧凑循环：

```
op_seg_kind[] / op_seg_start[] / op_seg_count[]
seg_dst[] / seg_src0[] / seg_src1[] / seg_n[] / seg_off[] / seg_const[]
```

---

## 3. 踩过的三个坑

### 3.1 空输入 AND 被当成「恒为 1」

`AND` 零输入在原引擎里语义是**常量 0**（悬空 net 为低电平）。
builder 最初建成 `EX_AND` + `lens=0`，求值时循环不执行、`v` 初值 1 → 结果反了。
**修正**：编译期把零输入 AND 直接降成 `EX_CONST(0)`。

### 3.2 寄存器 Q 的时序：新值要隔 2 拍才参与组合

旧引擎 `SWSignalEvalCPU`：

```
evaluate(): 在 _cur 上算组合 → 锁存写 _cur[Q] → 交换 _cur/_prev
readback(): 返回交换后的 _prev（= 本拍结果）
```

下一拍组合阶段读的 `_cur` 是**交换后的旧缓冲**，里面 Q 还是上上拍锁存的值。
即 **readback 看到的 Q，比组合阶段实际使用的 Q 新一拍**。

这不是笔误，是既有行为。新引擎必须复刻，否则寄存器反馈电路整体错拍
（实测差异从 0 涨到 3000+）。

**复刻方式**：维护两段 Q 历史 `applied_q`（参与本拍组合）与 `incoming_q`（下一拍用），
`latch()` 只写 `lock_state` 不写 `vals`，`roll_q()` 在两拍之间滚动。

**验证手段**：把旧引擎 `evaluate` 逐行手工复刻一遍，先证明「手工复刻 == 官方 readback 零差异」，
再用同样的时序去对拍 DAG。这一步是定位问题的关键——光看代码看不出两拍滞后。

### 3.3 热循环：分段 for-range 比单循环 while 快 14%

试过「一条扁平数组 + while + 多路 if」，比「按 op 分段 + for-range」**慢 14%**
（2.54ms vs 2.21ms）。GDScript 里 for-range 的迭代器开销远小于 while 的多路分支。

同理，`PackedInt32Array.duplicate()` 是原生 memcpy，比手写 for 循环拷贝**快 12%**，
所以拍前快照用 `duplicate()` 而不是复用缓冲逐元素拷贝。

---

## 4. 实测结果

### 4.1 正确性（`test_expr_parity.gd`）

逐拍逐 net 与旧 gate 表对比，5 个真实存档**全部零差异**：

| 存档 | gate | 唯一表达式 | 合并 | 差异 |
|---|---|---|---|---|
| 加法器3 | 246 | 216 | 30 | **0** |
| 16x计数器 | 6550 | 5752 | 798 | **0** |
| 计数器2 | 6944 | 6098 | 846 | **0** |
| 64x寄存器 | 32160 | 28242 | 3918 | **0** |
| 测试寄存器 | 32165 | 28247 | 3918 | **0** |

### 4.2 纯求值性能（`test_dag_ab.gd`，同进程交替 5 轮）

```
round0: DAG=2.225 ms  gate=2.707 ms  比值=0.82
round1: DAG=2.206 ms  gate=2.716 ms  比值=0.81
round2: DAG=2.202 ms  gate=2.733 ms  比值=0.81
round3: DAG=2.208 ms  gate=2.712 ms  比值=0.81
round4: DAG=2.198 ms  gate=2.704 ms  比值=0.81
中位: DAG=2.206 ms    gate=2.712 ms
```

**DAG 比原 gate 表快 19%。**（注：整机负载会漂移，必须以同进程交替测量为准；
单独跑两种配置得到 22ms vs 15ms 的对比是不可靠的。）

### 4.3 `evaluate()` 内部拆解（每拍 64 电路合计）

| 步骤 | 耗时 | 占比 |
|---|---|---|
| `evaluate`（表达式运算） | 2.047 ms | **92%** |
| `latch` | 0.076 ms | 3.4% |
| `roll_q` | 0.030 ms | 1.4% |
| `apply_q` | 0.029 ms | 1.3% |
| 源写入 | 0.028 ms | 1.3% |
| `duplicate`（拍前快照） | 0.011 ms | 0.5% |

单表达式均耗时 **0.092 µs**。

### 4.4 端到端（含回填/刷新）

```
DAG + 全显示         med=24.83 ms
gate表 + 全显示       med=25.18 ms
DAG + 只算三类元件     med=5.25 ms
gate表 + 只算三类元件   med=5.37 ms
```

完整路径下两者接近——因为回填/刷新占大头，掩盖了求值差异。

---

## 5. 结论与后续

1. **表达式去重本身收益有限**：64x 存档 25216 条 gate 只合并掉 3918 条（15%）。
   之前测到的「178 种唯一表达式」是**单电路内**的数字，全局是 22144 种。
   用户举的 `(a&b)&(a&b)` 场景在这批存档里不常见。

2. **DAG 的真正价值是求值快 19%**：靠的是「结果直写 primary slot + 操作数预解析成直接下标 +
   按 op 分段」，而不是去重本身。

3. **最大的性能杠杆仍是 `backfill_*` 两个开关**：
   `15.4ms → 5.3ms`（2.9 倍），远超 DAG 的 19%。

4. 若要进一步提速，方向是：
   - 把 `evaluate` 下沉到 GDExtension（GDScript 每表达式 92ns 已接近解释器下限）
   - 或利用「只算三类元件」模式做反向锥裁剪（但实测锥占 96.7%，收益有限）
