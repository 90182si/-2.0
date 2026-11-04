class_name SWSignalEvalCPU
extends RefCounted
# 数据驱动 CPU 求值引擎（T1.10 性能优化方案 A）
# 与 SWSignalEvalGPU 共用 SWGateProgram 扁平 gate 数组（stride 8），串行单循环求值，
# 替代逐组件的 GDScript 函数调用链（_compOut/_driverOut/_netSignal 等，每帧约 5 万次调用）。
#
# 语义与 GPU 引擎一致：
# - 组合求值按层（Kahn 拓扑保证跨层依赖，层内顺序无关）；NOT=1-x，AND=srcs 与（短路）；
# - 空驱动 AND = 恒 0；
# - 寄存器：clk 读本拍最新（写侧），D 读拍前（上一拍结果），首次 last_clk<0 只对齐不采样，
#   上升沿 0→1 采样 q=D；Q 真的翻了就在本拍再跑一遍组合，下游当拍可见新电平。
#
# ========== SPEC-04 结论：这里刻意保持「逐层全量单循环」 ==========
# 试过并在同进程 A/B 基准里证伪的三条增量方案（详见 SPEC-04 §6）：
#   1. 跨拍跳过（源没变则整轮不算）：ping-pong 缓冲滚动后跳过层会读到上一拍的旧值 →
#      16x 计数器直接跑错（不是慢，是错）。
#   2. 本轮内按层跳过未受影响层：每个 gate 要多做一次「是否脏」判断 + 脏表写入，
#      实测反而慢 ~40%（逐层判据的标量开销摊到每条 gate 上，比直接算一遍贵）。
#   3. 用脏表代替全局比较：同理，纯增加开销。
# 结论：在 GDScript 里，扁平表的**单循环直接算**就是最快形态；
# 真要拿增量收益必须走 GPU（全量并行，见 SWSignalEvalGPU），或把 SDF 求值下沉到 GDExtension。

const OP_INPUT := 0
const OP_NOT := 1
const OP_AND := 2
const OP_REG := 3
const OP_ALIAS := 4

var _prog: SWGateProgram
var _cur: PackedInt32Array   # 本拍 slot 值（输入源/组合已算/寄存器输出）
var _prev: PackedInt32Array  # 上一拍 slot 值（寄存器 D 读拍前；readback 目标）
var _reg_state: PackedInt32Array  # stride2: [q, last_clk]（last_clk<0 = NONE 首次）

# 保留开关：关掉时与本引擎最初实现完全一致（回归对拍/灰度用）
var eval_incremental: bool = false


func setup(prog: SWGateProgram) -> void:
	_prog = prog
	var n := prog.slot_count
	_cur.resize(n)
	_cur.fill(0)
	_prev.resize(n)
	_prev.fill(0)
	var rn := prog.reg_slots.size()
	_reg_state.resize(rn * 2)
	_reg_state.fill(0)
	for i in rn:
		_reg_state[i * 2 + 1] = -1


func init_reg_state(q: PackedInt32Array, last_clk: PackedInt32Array) -> void:
	for i in _prog.reg_slots.size():
		_reg_state[i * 2] = q[i] if i < q.size() else 0
		_reg_state[i * 2 + 1] = last_clk[i] if i < last_clk.size() else -1


# 拍前基线（同 GPU init_prev）：当前 net 电平 + 寄存器 Q
func init_prev(slots: PackedInt32Array) -> void:
	_prev = slots.duplicate()
	_cur = slots.duplicate()


func read_reg_state() -> PackedInt32Array:
	return _reg_state.duplicate()


# 源值按 input_slots 序写入本拍缓冲
func write_sources(vals: PackedInt32Array) -> void:
	var ins := _prog.input_slots
	var cur := _cur
	for i in ins.size():
		cur[ins[i]] = vals[i]


# 兼容接口（GPU 引擎同名方法）：本引擎无跨拍脏状态
func clear_changed() -> void:
	pass


func evaluate() -> void:
	_run_gates()
	# 寄存器锁存（组合之后执行：clk 读本拍值，D 读拍前快照 → 同拍内同时采样）
	var regs := _prog.reg_slots
	var rcs := _prog.reg_clk_slots
	var rds := _prog.reg_d_slots
	var rs := _reg_state
	var cur := _cur
	var q_changed := false
	for i in regs.size():
		var last_clk: int = rs[i * 2 + 1]
		var clk_slot: int = rcs[i]
		var d_slot: int = rds[i]
		var cur_clk: int = 0 if clk_slot < 0 else cur[clk_slot]
		var cur_d: int = 0 if d_slot < 0 else _prev[d_slot]
		if last_clk < 0:
			rs[i * 2 + 1] = cur_clk
		elif last_clk == 0 and cur_clk == 1:
			if rs[i * 2] != cur_d:
				q_changed = true
			rs[i * 2] = cur_d
			rs[i * 2 + 1] = cur_clk
		else:
			rs[i * 2 + 1] = cur_clk
		cur[regs[i]] = rs[i * 2]
	# Q 本拍真的翻了 → 用新 Q 再算一遍组合，下游（LED/连线）当拍即亮；
	# 否则下游要等到下一拍，表现为「寄存器贴图变了、灯泡却要等下一次信号变化」
	if q_changed:
		_run_gates()
	# 本拍值滚动为下一拍基线（readback 读 _prev = 本拍结果）
	var t := _prev
	_prev = cur
	_cur = t


# 组合逐层求值（写 _cur）：Kahn 拓扑层保证跨层依赖，层内顺序无关
func _run_gates() -> void:
	var g := _prog.gates
	var ls := _prog.level_starts
	var lc := _prog.level_counts
	var cur := _cur
	for lv in _prog.level_count:
		var start: int = ls[lv]
		if start < 0:
			continue
		var end: int = start + lc[lv]
		for gi in range(start, end):
			var base: int = gi * SWGateProgram.STRIDE
			var op: int = g[base]
			var dst: int = g[base + 1]
			# 热点分派：一条 gate 一次 if/elif。这里每拍跑几万次，别改成 match（实测慢 ~40%）。
			if op == OP_NOT:
				cur[dst] = 1 - cur[g[base + 4]]
			elif op == OP_ALIAS:
				# CSE 产物：直接复用已算出的公共子表达式结果
				cur[dst] = cur[g[base + 4]]
			elif op == OP_AND:
				var sc: int = g[base + 3]
				var v: int = 1
				if sc <= 0:
					v = 0  # 空驱动 AND = 恒 0（悬空低电平，与 eval shader 一致）
				else:
					for si in sc:
						v = v & cur[g[base + 4 + si]]
						if v == 0:
							break
				cur[dst] = v
			# OP_INPUT / OP_REG：无组合操作（源已由 write_sources 写入；寄存器在 evaluate 尾部锁存）


func readback() -> PackedInt32Array:
	return _prev
