class_name SWGateProgram extends RefCounted

# GPU 求值的静态数据流图（op_list，SPEC-01 §8 T1.10 + 用户方案「扁平布尔算子列表」）。
# 玩家电路 → 编译为「每 net 一个 slot + 每驱动组件一个 slot」的布尔算子表，
# 每轮 tick GPU 按拓扑层并行求值（ping-pong 双缓冲，见 sw_signal_compute_eval.glsl）。
#
# 布局：
#   slot 0 .. net_count-1           ：net slot（每根 net 一个，值 = 驱动者输出的线与）
#   slot net_count .. slot_count-1  ：comp slot（每驱动组件一个：源/门/寄存器）
# 写冲突规避（用户方案核心坑）：一个 net slot 只由一条 OP_AND 写；
# 组件输出写自己的 comp slot（OP_NOT/OP_REG/源由 CPU 写），net 再统一 AND 归并。
#
# gate 固定 stride 8（PackedInt32Array 展平，GPU 端按 stride 遍历）：
#   [op, dst_slot, level, src_count, s0, s1, s2, s3]
#   op：OP_INPUT（源，无 gate 逻辑，CPU 写）/ OP_NOT / OP_AND（src 数 ≤4，超了编译器折叠链）
#        / OP_REG（寄存器锁存，帧边界 pass）
#   level：拓扑层（Kahn 深度），逐层 dispatch 的调度依据；环路节点排到最后一层
const STRIDE := 8
const OP_INPUT := 0
const OP_NOT := 1
const OP_AND := 2
const OP_REG := 3
# OP_ALIAS：dst = src[0]（CSE 把重复子表达式指向第一个算出的结果）
const OP_ALIAS := 4

var gates := PackedInt32Array()
var gate_count := 0
var slot_count := 0
var net_count := 0
var comp_count := 0
var level_count := 0

# ========== SPEC-04 编译诊断（性能面板/测试断言用） ==========
# 原始 gate 条数（当前化简不改变 gate 数，保留字段供对拍断言用）
var raw_gate_count := 0
# 判定在反馈环上的 slot 数（环上中间态是计数器时序的一部分，任何重写都不能动它）
var loop_nets := 0
# 环上 slot 明细（与 slot_count 同长，1 = 在某个反馈环里）。
# SWGateOptimizer 用它划安全边界：环上的 gate 一律不化简。
var loop_slot_flags := PackedByteArray()
# 编译（含环检测）耗时，微秒
var opt_usec := 0
# CSE 合并掉的重复子表达式条数
var cse_merged := 0

# SWNet → net slot
var net_to_slot: Dictionary = {}
# SWBuildCompoentCircuit → comp slot
var comp_to_slot: Dictionary = {}
# netId → net slot（信号纹理写入 / readback 用；netId 是全局唯一的渲染索引）
var net_id_to_slot: Dictionary = {}
# slot → SWNet（反查，O(1)）：折叠时判断「这个 slot 是不是一根对外可观测的 net」
var slot_to_net: Dictionary = {}

# 源 comp slot（时钟/按钮/开关）：CPU 每帧把 pressed/curSig 写入这些 slot
var input_slots := PackedInt32Array()
# 源组件列表（顺序与 input_slots 一一对应）：集成/测试取源输出值时用
var input_comps: Array = []
# 寄存器 comp slot（Q 输出）：帧边界锁存 pass 写入
var reg_slots := PackedInt32Array()
# 寄存器组件列表（顺序与 reg_slots 一一对应）：集成/测试取 qState/lastClk 用
var reg_comps: Array = []
# 灯泡组件列表（编译期收集，仅非线建筑）：回填时批量刷显示，
# 避免每拍遍历 circuit.buildArr（电线占绝大多数）逐建筑查组件
var led_comps: Array = []
# 灯泡的内层状态刷新组件（LED 的 reCalSignals 只是「读 input net → buildStateChanged」；
# 设备层刷新 = buildRef + 帧槽写入，用渲染组件直接做，省掉 LED 组件的方法调用套壳）。
# 顺序与 led_comps 一一对应。
var led_refresh_comps: Array = []
# 每个 LED 读到哪些 net slot（编译期算好）：回填阶段直接按 slot 判亮灭，
# 不再走「LED.reCalSignals → netBit → SWNet 对象」的逐 LED 对象链
# （64x 存档实测 13.8k 次/拍、59ms）。
var led_src_slots: Array = []
# LED 批量刷新的平坦索引（见编译器注释）：
#   led_refresh_comps[i] 是第 i 个 LED 的渲染组件；
#   led_src_flat / led_src_offs / led_src_lens 描述它读哪几个 net slot。
var led_src_flat := PackedInt32Array()
var led_src_offs := PackedInt32Array()
var led_src_lens := PackedInt32Array()
# 每拍真正发生电平变化的 net slot 数（回填时统计，供 LED 快速路径判空）
var led_prev_level := PackedInt32Array()

# ========== 回填扁平表（64x 存档卡顿治理） ==========
# 每拍要把「本拍 slot 值」写回 net.curSignal。原实现遍历 net_to_slot 这个 Dictionary，
# 每根 net 一次哈希查表 + 两次 SWNet 属性访问；64x 存档 11392 根 net 实测 8ms/拍。
# 这里改成两条平行数组（下标即 net 序号），回填时纯下标访问：
#   net_list[i]   ：第 i 根 net（顺序与 net_slots[i] 一一对应）
#   net_slots[i]  ：它对应的 slot
var net_list: Array = []
var net_slots := PackedInt32Array()
# 回填缓存：上次写进各 net 的电平（0/1，与 net_list 同序）。
# 用它代替 net.curSignal（枚举属性，读写各一次类型转换）做同值判断，
# 后者在大存档每拍上万次访问上是纯开销。
var net_prev_bit := PackedInt32Array()

# ========== 组合门显示刷新扁平表（64x 存档卡顿治理） ==========
# 组合门（主要是 NOT）的显示刷新本质是「本拍算出来的电平 → 贴图帧」，
# 而绝大多数组合门一拍内电平不变。这三张表让回填阶段直接按 slot 比较后批量刷新，
# 不再进组件层的 reCalSignals → evaluate → netBit 四层间接调用。
# gate_out_slots[i]    ：该组件输出所在 slot（比较用）
# gate_refresh_comps[i]：该组件的渲染组件（直接写 signal_state + 帧槽）
# gate_prev_level[i]   ：上一次刷给它贴图的电平（-1 = 尚未刷过，首拍必刷）
var gate_out_slots := PackedInt32Array()
var gate_refresh_comps: Array = []
var gate_prev_level := PackedInt32Array()
# 显示取反标记（与 gate_prev_level 同序）：非门贴图按**输入**电平选帧（组件 evaluate 里
# buildStateChanged 传的就是输入位），而 gate_out_slots 存的是输出位，两者相反。
# 1 = 写入前取反（非门），0 = 直写（其他组合门）。
var gate_display_invert := PackedByteArray()
# 本拍有电平变化、需要重新刷显示的 gate 下标（回填阶段填充，下一拍只会更小）
var dirty_gate_idx := PackedInt32Array()
# 组件层兜底刷新的紧凑表：只在「不属于已批量处理类别」时用它。
# 编译期过滤掉 LED（走 led_comps）与组合门（走 gate_out_slots），剩下的通常是时钟/按钮等
# 源类显示件。64x 存档里这个表通常为空，回填阶段就不用再逐组件跑 evalMark 循环。
var fallback_display_comps: Array = []
# 需要每拍刷显示的非时序组件（NOT / LED / 其他组合显示件）。
# 与 all_comps 的区别：这是编译期定死的扁平表，`_applyBackendResult` 的 notify 刷新
# 直接遍历它 + 按 comp.evalMark 判本拍是否已刷，省掉每个组件一次 isStateful() 虚调用
# （64x 存档实测 61.4k 次/拍、9.25ms）。
var display_comps: Array = []
# 全部非线组件（编译期收集）：首轮回填全量刷显示用（读档/重建后贴图被 resetBuildState 重置）
var all_comps: Array = []
# 首轮回填是否已完成：首轮需全量刷显示（未变化的 net/寄存器不进通知集），之后每拍增量刷
var display_synced: bool = false
# ========== 视野裁剪索引表（见 SWCircuitControl.set_view_rect / _refresh_view_index） ==========
# 只有视野内的电线与非门需要跟随电路刷新，所以回填循环改成只遍历下面两张下标表：
#   net_view_idx[k] -> net_list/net_slots/net_prev_bit 的下标 i
#   gate_view_idx[k] -> gate_out_slots/gate_refresh_comps/gate_prev_level 的下标 gi
# 表只在「视口变了之后的第一拍」重建一次（cull_stamp 比对），稳定镜头时零成本；
# 重建时把视野外元件的 prev 哨兵置 -1（-1 既不是 0 也不是 1），于是它回到视野内的那一拍
# 必然判为「电平变了」，自动把正确值补写进信号纹理/帧槽，不需要额外的补算逻辑。
var cull_stamp: int = -1
var net_view_idx := PackedInt32Array()
var gate_view_idx := PackedInt32Array()
# 寄存器的 clk / d 输入 net slot（锁存 pass 读：clk_rise 时 q = d_prev）
var reg_clk_slots := PackedInt32Array()
var reg_d_slots := PackedInt32Array()

# 每层的 gate 区间 [start, count]（dispatch 调度表；gate 已按 level 排序）
var level_starts := PackedInt32Array()
var level_counts := PackedInt32Array()

# 读一条 gate 的源 slot 列表（-1 占位）
func gate_srcs(gi: int) -> Array[int]:
	var base: int = gi * STRIDE
	var n: int = gates[base + 3]
	var out: Array[int] = []
	for i in n:
		out.append(gates[base + 4 + i])
	return out
