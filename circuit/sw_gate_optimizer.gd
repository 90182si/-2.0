class_name SWGateOptimizer extends RefCounted

# ==========================================================================
# gate 表化简器：把 SWGateProgram 改写成等价但更「高级」的形态
#
# 用途：性能面板关掉「电线/非门跟随电平」时，求值走这一份简化程序
# （SWCircuitControl.use_simplified_eval）；打开时走未简化的原程序，
# 玩家才能看到每一级门在动。
#
# ========== 为什么化简只能在 gate 层做、且不许动 slot ==========
# slot 编号是**对外契约**：回填阶段按 net_slots / led_src_flat / gate_out_slots
# 直接读 slots[i] 决定连线颜色、灯泡亮灭、门贴图。删 slot 或重排编号会让这些
# 表全部指向错的电平。所以本文件只改「这一条 gate 怎么写这个 slot」，
# dst 编号、gate 条数、拓扑层表、回填扁平表全部原样沿用，产物可以直接喂给
# SWSignalEvalCPU / SWSignalEvalGPU / SWExprBuilder 三个消费者。
#
# keep level 不变是安全的：下面每条规则都只会让 src 指向**更低层**的 slot
# （ALIAS 链只会往更早算完的方向走），按原 level 调度仍然先算 src 再算 dst。
#
# ========== 规则（逐位等价，都是用户点名的「尽量做简化」） ==========
#   1. ALIAS(ALIAS(x)) → ALIAS(x)      链压缩，一路指到真正产出值的 slot
#   2. NOT(NOT(x))     → ALIAS(x)      ← 双非门抵消，玩家最想看到的化简
#   3. NOT(ALIAS(x))   → NOT(x)
#   4. AND(x)          → ALIAS(x)      ← 单输入线与就是直通
#   5. AND(x, x, …)    → 去重后按 4 / 继续
#   6. AND(…, 0, …)    → AND()         ← 线与里有恒 0 项，整体恒 0
#
# ========== 折到不动点 ==========
# optimize 不是扫一遍就结束：每一轮只扫一遍 gate 表，而某个 slot 刚被化简可能让
# 本轮已经扫过的 gate 获得新的化简机会，所以反复折直到一轮下来一条 gate 都没变
# （简化量为 0）才停（passes 诊断字段给出实际跑了几轮）。
#
# ========== 刻意不做的事 ==========
# · NOT(0) → 常量 1：gate 层没有常量 1 的写法（只有「空输入 AND = 0」）
# · 把 AND + NOT 合成一条 NAND：三个消费者都只认 OP_NOT / OP_AND / OP_ALIAS，
#   「高级门」只体现在悬浮文本的显示名上（见 SWExprDescribe）
# · 把 NAND(NOT,NOT) 认成 OR、把 4 个 NAND 认成 XOR：同理，gate 层没有这两种 op，
#   合并/删 gate 还会撞坏 slot 回填契约；这类昵称只出现在悬停文本里
# · 环上 slot 一律不碰：反馈环里的中间态是计数器时序的一部分
# ==========================================================================

# 上一次 optimize 实际改写了多少条 gate（诊断 / 测试断言）
var optimized_gates: int = 0
# 上一次 optimize 跑到不动点用了几轮有改动的迭代（诊断 / 测试断言）
var passes: int = 0
# 不动点迭代的硬上限：正常电路一两轮就收敛，这里只是死循环保险
const MAX_PASSES := 32
# 不动点迭代里的本轮改动计数
var _changed: int = 0

# 一份 gate 表 → 化简后的 gate 表。
# 输入不会被修改；产物与输入的 slot 空间、dst 编号、拓扑层表、回填扁平表完全一致。
func optimize(prog: SWGateProgram) -> SWGateProgram:
	var out := SWGateProgram.new()
	_copy_shared(prog, out)
	optimized_gates = 0
	passes = 0
	_changed = 0
	out.gates = prog.gates.duplicate()
	out.gate_count = prog.gate_count
	var n: int = prog.slot_count
	if prog.gate_count <= 0 or n <= 0:
		return out

	var g := prog.gates
	# 每 slot 的写入形态：编译器保证一个 slot 只由一条 gate 写（组件 slot 一条、
	# net slot 一条、>4 驱动的折叠中间 slot 各一条），所以这里可以按 dst 直存。
	var op := PackedInt32Array()
	op.resize(n)
	op.fill(SWGateProgram.OP_INPUT)
	var srcs: Array = []
	srcs.resize(n)
	for i in n:
		srcs[i] = PackedInt32Array()
	for gi in prog.gate_count:
		var base: int = gi * SWGateProgram.STRIDE
		var dst: int = g[base + 1]
		if dst < 0 or dst >= n:
			continue
		op[dst] = g[base]
		var arr := PackedInt32Array()
		for k in g[base + 3]:
			arr.append(g[base + 4 + k])
		srcs[dst] = arr

	# 不动点迭代：一轮只扫一遍 gate 表，而「某个 slot 刚被化简」可能让**本轮已经
	# 扫过**的 gate 获得新的化简机会（ALIAS 链、去重后又暴露出单输入），所以必须
	# 反复折，直到一轮下来一条 gate 都没变（简化量为 0）才停。
	# 不设固定轮数（用户要求折到不能再折），MAX_PASSES 只是死循环保险。
	var flags: PackedByteArray = prog.loop_slot_flags
	while passes < MAX_PASSES:
		_changed = 0
		for gi in prog.gate_count:
			var dst: int = g[gi * SWGateProgram.STRIDE + 1]
			if dst < 0 or dst >= n:
				continue
			if dst < flags.size() and flags[dst] == 1:
				continue   # 反馈环上的中间态属于时序：任何重写都不许动
			_simplify_slot(dst, op, srcs, flags)
		if _changed == 0:
			break      # 本轮零改动 = 已到不动点
		passes += 1

	# 写回 gate 表：dst / level / gate 条数一律沿用，只有 op 与 srcs 换成化简后的
	var out_gates := PackedInt32Array()
	out_gates.resize(g.size())
	out_gates.fill(0)
	var applied := 0
	for gi in prog.gate_count:
		var base: int = gi * SWGateProgram.STRIDE
		var dst: int = g[base + 1]
		out_gates[base + 1] = dst
		out_gates[base + 2] = g[base + 2]
		if dst < 0 or dst >= n:
			out_gates[base + 0] = g[base + 0]
			out_gates[base + 3] = g[base + 3]
			for k in g[base + 3]:
				out_gates[base + 4 + k] = g[base + 4 + k]
			continue
		var ws: PackedInt32Array = srcs[dst]
		var cnt: int = mini(ws.size(), 4)
		out_gates[base + 0] = op[dst]
		out_gates[base + 3] = cnt
		var differs: bool = op[dst] != g[base + 0] or cnt != g[base + 3]
		for k in cnt:
			out_gates[base + 4 + k] = ws[k]
			if ws[k] != g[base + 4 + k]:
				differs = true
		if differs:
			applied += 1
	out.gates = out_gates
	optimized_gates = applied
	return out

# 单个 slot 的化简（原地改 op / srcs，判等由 _set_slot 兜住）
func _simplify_slot(s: int, op: PackedInt32Array, srcs: Array, flags: PackedByteArray) -> void:
	var cur: PackedInt32Array = srcs[s]
	match op[s]:
		SWGateProgram.OP_ALIAS:
			# 规则 1：ALIAS(ALIAS(x)) → ALIAS(x)。直通链要自己收短，
			# 否则链尾的化简（比如 NOT(NOT) → ALIAS）要等到别的 gate
			# 引用它时才能被穿透，直通链本身会一直挂在中间 slot 上
			if cur.is_empty():
				return
			var t := _resolve(cur[0], op, srcs, flags)
			if t != cur[0] and t != s:
				_set_slot(s, SWGateProgram.OP_ALIAS, [t], op, srcs)
		SWGateProgram.OP_NOT:
			if cur.is_empty():
				return
			var a := _resolve(cur[0], op, srcs, flags)
			# NOT(NOT(x)) → x：用户点名的双非门抵消
			if a != s and op[a] == SWGateProgram.OP_NOT:
				var inner: PackedInt32Array = srcs[a]
				if not inner.is_empty():
					var b := _resolve(inner[0], op, srcs, flags)
					if b != s:
						_set_slot(s, SWGateProgram.OP_ALIAS, [b], op, srcs)
						return
			if a != cur[0]:
				_set_slot(s, SWGateProgram.OP_NOT, [a], op, srcs)
		SWGateProgram.OP_AND:
			if cur.is_empty():
				return   # 常量 0（悬空 net 的电平），已经是最终形态
			var res: Array[int] = []
			for src in cur:
				var r := _resolve(src, op, srcs, flags)
				# 线与里出现恒 0 项 → 整体恒 0
				if op[r] == SWGateProgram.OP_AND and (srcs[r] as PackedInt32Array).is_empty():
					_set_slot(s, SWGateProgram.OP_AND, [], op, srcs)
					return
				if not res.has(r):
					res.append(r)   # 去重：AND(a, a) 与 AND(a) 等价
			if res.size() == 1:
				_set_slot(s, SWGateProgram.OP_ALIAS, res, op, srcs)   # 单输入线与 = 直通
			else:
				_set_slot(s, SWGateProgram.OP_AND, res, op, srcs)

# ALIAS 链压缩：一路指到真正产出值的那个 slot。
# 环上的 ALIAS 不穿过去——反馈环的中间态是时序的一部分，跨过去会改变迭代收敛路径。
func _resolve(slot: int, op: PackedInt32Array, srcs: Array, flags: PackedByteArray) -> int:
	var cur: int = slot
	var total: int = op.size()
	for _i in 32:
		if cur < 0 or cur >= total or op[cur] != SWGateProgram.OP_ALIAS:
			break
		if cur < flags.size() and flags[cur] == 1:
			break
		var arr: PackedInt32Array = srcs[cur]
		if arr.is_empty():
			break
		var nxt: int = arr[0]
		if nxt < 0 or nxt >= total or nxt == cur:
			break
		cur = nxt
	return cur

# 原地写一个 slot 的形态；值没变就什么都不做（_changed 是收敛判据）
func _set_slot(s: int, new_op: int, new_srcs: Array,
		op: PackedInt32Array, srcs: Array) -> void:
	var old: PackedInt32Array = srcs[s]
	if op[s] == new_op and old.size() == new_srcs.size():
		var same := true
		for i in old.size():
			if old[i] != int(new_srcs[i]):
				same = false
				break
		if same:
			return
	op[s] = new_op
	var arr := PackedInt32Array()
	for v in new_srcs:
		arr.append(int(v))
	srcs[s] = arr
	_changed += 1

# 只读字段全部共享引用：两份 prog 描述的是同一个 slot 空间，缓存（net_prev_bit /
# gate_prev_level / led_prev_level 等）也该是同一份，否则切换开关时会白白全量重刷一屏。
func _copy_shared(src: SWGateProgram, dst: SWGateProgram) -> void:
	dst.slot_count = src.slot_count
	dst.net_count = src.net_count
	dst.comp_count = src.comp_count
	dst.level_count = src.level_count
	dst.level_starts = src.level_starts
	dst.level_counts = src.level_counts
	dst.input_slots = src.input_slots
	dst.input_comps = src.input_comps
	dst.reg_slots = src.reg_slots
	dst.reg_comps = src.reg_comps
	dst.reg_clk_slots = src.reg_clk_slots
	dst.reg_d_slots = src.reg_d_slots
	dst.net_to_slot = src.net_to_slot
	dst.comp_to_slot = src.comp_to_slot
	dst.net_id_to_slot = src.net_id_to_slot
	dst.slot_to_net = src.slot_to_net
	dst.net_list = src.net_list
	dst.net_slots = src.net_slots
	dst.net_prev_bit = src.net_prev_bit
	dst.loop_slot_flags = src.loop_slot_flags
	dst.loop_nets = src.loop_nets
	dst.raw_gate_count = src.raw_gate_count
	dst.cse_merged = src.cse_merged
	dst.opt_usec = src.opt_usec
	dst.led_comps = src.led_comps
	dst.led_refresh_comps = src.led_refresh_comps
	dst.led_src_slots = src.led_src_slots
	dst.led_src_flat = src.led_src_flat
	dst.led_src_offs = src.led_src_offs
	dst.led_src_lens = src.led_src_lens
	dst.led_prev_level = src.led_prev_level
	dst.gate_out_slots = src.gate_out_slots
	dst.gate_refresh_comps = src.gate_refresh_comps
	dst.gate_prev_level = src.gate_prev_level
	dst.gate_display_invert = src.gate_display_invert
	dst.dirty_gate_idx = src.dirty_gate_idx
	dst.fallback_display_comps = src.fallback_display_comps
	dst.display_comps = src.display_comps
	dst.all_comps = src.all_comps
