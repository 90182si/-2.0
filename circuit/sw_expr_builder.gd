class_name SWExprBuilder extends RefCounted

# ==========================================================================
# SWGateProgram（每 slot 一条 gate）→ SWExprProgram（唯一表达式 DAG + 拓扑序）
#
# 映射：
#   1. 每个原 slot 的「值来源」是一个表达式：NOT(srcs) / AND(srcs) / 源(=EX_INPUT)
#   2. 用 (op, 归一化 srcs) 去重：srcs 先映射到各自的主写 slot，再做键
#      —— 这就是用户说的「把重复的 (a&b) 提成中间表达式 S2」
#   3. 去重后对表达式做拓扑排序（迭代 Kahn）
#   4. 表达式结果写进它服务的第一个 slot；其余共享 slot 进 extra 表
#
# 环路：环上的表达式不参与去重（时序状态必须各自独立），
#   拓扑排序时环上残留按原下标追加，保证确定性。
# ==========================================================================

# 是否启用表达式去重
var enable_dedup: bool = true


func build(prog: SWGateProgram, loop_slots: Array[bool] = []) -> SWExprProgram:
	var ep := SWExprProgram.new()
	var n: int = prog.slot_count
	ep.slot_count = n

	# ---- 1. 读出每个 slot 的写入 gate ----
	var g := prog.gates
	var slot_op := PackedInt32Array()
	var slot_srcs: Array = []
	slot_op.resize(n)
	slot_op.fill(SWExprProgram.EX_INPUT)
	slot_srcs.resize(n)
	for i in n:
		slot_srcs[i] = PackedInt32Array()
	for gi in prog.gate_count:
		var base: int = gi * SWGateProgram.STRIDE
		var dst: int = g[base + 1]
		if dst < 0 or dst >= n:
			continue
		var cnt: int = g[base + 3]
		var arr := PackedInt32Array()
		for k in cnt:
			arr.append(g[base + 4 + k])
		slot_srcs[dst] = arr
		match g[base]:
			SWGateProgram.OP_NOT:
				slot_op[dst] = SWExprProgram.EX_NOT
			SWGateProgram.OP_AND:
				slot_op[dst] = SWExprProgram.EX_AND
			SWGateProgram.OP_ALIAS:
				slot_op[dst] = SWExprProgram.EX_ALIAS
			_:
				slot_op[dst] = SWExprProgram.EX_INPUT

	# ---- 2. 逐 slot 建表达式（迭代到不动点，让 src 先就位） ----
	# slot_expr[s] = 该 slot 服务的表达式下标（-1 = 外部输入）
	var slot_expr := PackedInt32Array()
	slot_expr.resize(n)
	slot_expr.fill(-1)
	var expr_keys: Dictionary = {}
	# 表达式临时记录
	var ex_op: Array[int] = []
	var ex_srcs: Array = []      # 已解析成「src 的主写 slot」的下标数组
	var ex_const: Array[int] = []
	var ex_primary: Array[int] = []

	var pending := PackedInt32Array()
	for s in n:
		if slot_op[s] != SWExprProgram.EX_INPUT:
			pending.append(s)

	while not pending.is_empty():
		var next_pending := PackedInt32Array()
		var progressed := false
		for s in pending:
			var srcs: PackedInt32Array = slot_srcs[s]
			var resolved := PackedInt32Array()
			var ready := true
			for src in srcs:
				if src < 0 or src >= n:
					ready = false
					break
				if slot_op[src] != SWExprProgram.EX_INPUT and slot_expr[src] < 0:
					ready = false
					break
				# 操作数指向「该 src 的主写 slot」——表达式结果就写在那里
				resolved.append(src if slot_op[src] == SWExprProgram.EX_INPUT \
						else ex_primary[slot_expr[src]])
			if not ready:
				next_pending.append(s)
				continue
			progressed = true
			var op: int = slot_op[s]
			var cval := 0
			if op == SWExprProgram.EX_AND and resolved.is_empty():
				op = SWExprProgram.EX_CONST
				cval = 0
			var key := "%d|%s" % [op, _join(resolved)]
			var can_dedup: bool = enable_dedup and not (s < loop_slots.size() and loop_slots[s])
			if can_dedup and expr_keys.has(key):
				slot_expr[s] = expr_keys[key]
				ep.merged_from += 1
				continue
			var idx: int = ex_op.size()
			ex_op.append(op)
			ex_srcs.append(resolved)
			ex_const.append(cval)
			ex_primary.append(s)
			slot_expr[s] = idx
			if can_dedup:
				expr_keys[key] = idx
		if not progressed:
			# 剩余是环：强制建表达式，不做去重（回边指向原 slot，读上一拍值）
			for s in next_pending:
				var srcs: PackedInt32Array = slot_srcs[s]
				var resolved := PackedInt32Array()
				for src in srcs:
					if src < 0 or src >= n:
						continue
					if slot_op[src] == SWExprProgram.EX_INPUT or slot_expr[src] < 0:
						resolved.append(src)
					else:
						resolved.append(ex_primary[slot_expr[src]])
				var idx: int = ex_op.size()
				ex_op.append(slot_op[s])
				ex_srcs.append(resolved)
				ex_const.append(0)
				ex_primary.append(s)
				slot_expr[s] = idx
			next_pending.clear()
		pending = next_pending

	# ---- 3. 落表 ----
	var ex_n: int = ex_op.size()
	ep.expr_count = ex_n
	ep.ops.resize(ex_n)
	ep.src_offs.resize(ex_n)
	ep.src_lens.resize(ex_n)
	ep.const_val.resize(ex_n)
	ep.primary.resize(ex_n)
	var flat := PackedInt32Array()
	for i in ex_n:
		ep.ops[i] = ex_op[i]
		ep.src_offs[i] = flat.size()
		var vp: PackedInt32Array = ex_srcs[i]
		ep.src_lens[i] = vp.size()
		flat.append_array(vp)
		ep.const_val[i] = ex_const[i]
		ep.primary[i] = ex_primary[i]
	ep.src_flat = flat
	ep.slot_expr = slot_expr

	# ---- 4. 附加写目标（同一表达式服务多个 slot） ----
	var extra_lists: Array = []
	extra_lists.resize(ex_n)
	for i in ex_n:
		extra_lists[i] = PackedInt32Array()
	for s in n:
		var ei: int = slot_expr[s]
		if ei >= 0 and ep.primary[ei] != s:
			var lst: PackedInt32Array = extra_lists[ei]
			lst.append(s)
			extra_lists[ei] = lst
	var xs := PackedInt32Array()
	xs.resize(ex_n + 1)
	var xd := PackedInt32Array()
	for i in ex_n:
		xs[i] = xd.size()
		xd.append_array(extra_lists[i])
	xs[ex_n] = xd.size()
	ep.extra_start = xs
	ep.extra_dst = xd

	# ---- 5. 拓扑序 ----
	ep.order = _topo_order(ep)
	# ---- 5b. 按 op 分段展开执行表（热路径用） ----
	_build_segments(ep)

	# ---- 6. 寄存器锁存表 ----
	ep.lock_q_slot = prog.reg_slots.duplicate()
	ep.lock_clk_slot = prog.reg_clk_slots.duplicate()
	ep.lock_d_slot = prog.reg_d_slots.duplicate()
	var rn := ep.lock_q_slot.size()
	ep.lock_state.resize(rn * 2)
	ep.lock_state.fill(0)
	for i in rn:
		ep.lock_state[i * 2 + 1] = -1

	# ---- 7. 挂接原生求值器（GDExtension，可用则用） ----
	if enable_native:
		ep.attach_native()
	return ep


# 是否尝试使用原生求值器（GDExtension）。
#
# 默认开启：原生求值比 GDScript 快 8.7 倍（64x 存档 2.39ms → 0.28ms），
# 且与 GDScript 版逐拍逐 slot 零差异（5 个真实存档验证）。
#
# 历史上的偶发段错误已定位并修复（SPEC-06 §4）：
#   根因是 evaluate() 里遍历附加写目标表时用了 `m_extra_start[i + 1]`，
#   但没有校验 extra_start 的实际长度 ≥ expr_count + 1 —— 长度不足时越界读堆内存。
#   ASan 直接报 heap-buffer-overflow at sw_expr_eval.cpp:190。
#   修复：循环上界取 min(expr_count, extra_start.size() - 1)，并补齐相关边界检查。
#   修复后 20 轮压力测试零崩溃。
#
# 扩展未构建/加载失败时自动回退到 GDScript 实现（attach_native 返回 false）。
var enable_native: bool = true


# 把拓扑序切成「同 op 连续段」，并为每段预展开 dst/src 下标数组。
# 段内一条 for-range 循环（GDScript 里比 while+switch 快约 14%）。
func _build_segments(ep: SWExprProgram) -> void:
	var n: int = ep.expr_count
	var seg_kind := PackedInt32Array()
	var seg_start := PackedInt32Array()
	var seg_cnt := PackedInt32Array()
	var dst := PackedInt32Array()
	var src0 := PackedInt32Array()
	var src1 := PackedInt32Array()
	var sn := PackedInt32Array()
	var soff := PackedInt32Array()
	var sconst := PackedInt32Array()
	var i := 0
	while i < n:
		var ei: int = ep.order[i]
		var kind: int = ep.ops[ei]
		var start := dst.size()
		var cnt := 0
		while i < n:
			var ej: int = ep.order[i]
			if ep.ops[ej] != kind:
				break
			var off: int = ep.src_offs[ej]
			var ln: int = ep.src_lens[ej]
			dst.append(ep.primary[ej])
			src0.append(ep.src_flat[off] if ln >= 1 else 0)
			src1.append(ep.src_flat[off + 1] if ln >= 2 else 0)
			sn.append(ln)
			soff.append(off)
			sconst.append(ep.const_val[ej])
			cnt += 1
			i += 1
		seg_kind.append(kind)
		seg_start.append(start)
		seg_cnt.append(cnt)
	ep.op_seg_kind = seg_kind
	ep.op_seg_start = seg_start
	ep.op_seg_count = seg_cnt
	ep.seg_dst = dst
	ep.seg_src0 = src0
	ep.seg_src1 = src1
	ep.seg_n = sn
	ep.seg_off = soff
	ep.seg_const = sconst


static func _join(arr: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for v in arr:
		parts.append(str(v))
	return ".".join(parts)


# 迭代 Kahn：操作数指向的 slot 若是某个表达式的主写目标，则该表达式必须先算。
func _topo_order(ep: SWExprProgram) -> PackedInt32Array:
	var ex_n: int = ep.expr_count
	# slot -> 服务它的表达式（反向：主写目标恰好是 slot 的那个表达式）
	var expr_of_primary := {}
	for i in ex_n:
		expr_of_primary[ep.primary[i]] = i
	var indeg := PackedInt32Array()
	indeg.resize(ex_n)
	indeg.fill(0)
	var out_cnt := PackedInt32Array()
	out_cnt.resize(ex_n)
	out_cnt.fill(0)
	for i in ex_n:
		var off: int = ep.src_offs[i]
		var ln: int = ep.src_lens[i]
		for k in ln:
			var p: int = ep.src_flat[off + k]
			if expr_of_primary.has(p):
				var dep: int = expr_of_primary[p]
				if dep != i:
					indeg[i] += 1
					out_cnt[dep] += 1
	var out_start := PackedInt32Array()
	out_start.resize(ex_n + 1)
	var acc := 0
	for i in ex_n:
		out_start[i] = acc
		acc += out_cnt[i]
	out_start[ex_n] = acc
	var out_to := PackedInt32Array()
	out_to.resize(acc)
	var cursor := out_start.duplicate()
	for i in ex_n:
		var off: int = ep.src_offs[i]
		var ln: int = ep.src_lens[i]
		for k in ln:
			var p: int = ep.src_flat[off + k]
			if expr_of_primary.has(p):
				var dep: int = expr_of_primary[p]
				if dep != i:
					out_to[cursor[dep]] = i
					cursor[dep] += 1
	var queue := PackedInt32Array()
	for i in ex_n:
		if indeg[i] == 0:
			queue.append(i)
	var order := PackedInt32Array()
	var head := 0
	while head < queue.size():
		var v: int = queue[head]
		head += 1
		order.append(v)
		for k in range(out_start[v], out_start[v + 1]):
			var w: int = out_to[k]
			indeg[w] -= 1
			if indeg[w] == 0:
				queue.append(w)
	if order.size() < ex_n:
		var in_order := {}
		for v in order:
			in_order[v] = true
		for i in ex_n:
			if not in_order.has(i):
				order.append(i)
	return order
