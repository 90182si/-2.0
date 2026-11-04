class_name SWExprProgram extends RefCounted

# ==========================================================================
# SPEC-05 · 唯一表达式 DAG + 显式拓扑序求值（用户方案落地）
#
# 背景（实测数据，见 SPEC-05 §1）：
#   现有 gate 表是「每个 slot 一条 gate」，重复的 (op, srcs) 在同一电路里大量出现
#   （64x 存档：25216 条 gate，按电路去重后 22144 条唯一表达式）。
#   原调度是「按拓扑层 dispatch」，层内 gate 之间没有执行顺序保证，
#   因此同层的重复表达式一旦共享结果，后执行的会读到上一拍残留值
#   （实测加法器错 4 处、64x 错 28493 处）——这就是必须在**显式拓扑序**下才能做去重的原因。
#
# 本文件的解法：
#   1. (op, srcs) 相同的运算全部指向同一个「表达式」；
#   2. 对表达式做拓扑排序，得到确定的执行序列；
#   3. 每拍按序列跑一遍，每个唯一表达式只算一次；
#   4. 表达式的结果**直接写进它服务的第一个原 slot**（primary_slot），
#      其余共享同一表达式的 slot 由 spread 表补写。
#
# 产物布局（全部 PackedInt32Array，缓存友好）：
#   ops[i]          ：表达式 i 的运算类型（EX_NOT / EX_AND / EX_CONST / EX_ALIAS）
#   src_flat/offs/lens：表达式 i 的操作数（存的是 vals 的直接下标）
#   primary[i]      ：表达式 i 的结果写进哪个原 slot
#   order           ：拓扑序（执行顺序）
#
# vals 的长度 = 原 slot 空间（slot_count），不含额外表达式槽。
# 源与寄存器 Q 的值由外部写入；表达式结果覆盖它们各自服务的原 slot。
# ==========================================================================

# 运算类型
const EX_NONE := -1
const EX_INPUT := 0     # 外部输入（源 / 寄存器 Q）：不产运算，直接读
const EX_NOT := 1
const EX_AND := 2
const EX_CONST := 3
const EX_ALIAS := 4     # 直连

var slot_count: int = 0
var expr_count: int = 0

# 表达式表
var ops := PackedInt32Array()
var src_offs := PackedInt32Array()
var src_lens := PackedInt32Array()
var src_flat := PackedInt32Array()
var const_val := PackedInt32Array()
# 主写目标：表达式结果写进这个原 slot
var primary := PackedInt32Array()

# 拓扑序（执行顺序，元素为 expr 下标）
var order := PackedInt32Array()

# 每个原 slot 的服务表达式（-1 = 源/寄存器 Q 等外部值）
var slot_expr := PackedInt32Array()

# 附加写目标（同一表达式服务 2+ 个 slot 时，主目标之外的其余 slot）
# CSR：extra_start[expr] .. extra_start[expr+1]
var extra_start := PackedInt32Array()
var extra_dst := PackedInt32Array()

# 诊断
var merged_from: int = 0   # 被合并掉的运算条数

# ========== 按 op 分段的执行表（编译期生成，热路径直接用） ==========
# 拓扑序被切成若干「同 op 连续段」，每段一条 for-range 紧凑循环。
# 段内所有下标都是 vals 的直接下标（无二层寻址）。
var op_seg_kind := PackedInt32Array()   # 每段的 op 类型
var op_seg_start := PackedInt32Array()  # 该段在各表中的起点
var op_seg_count := PackedInt32Array()  # 该段的条数
var seg_dst := PackedInt32Array()       # 目标 slot
var seg_src0 := PackedInt32Array()      # 操作数 0
var seg_src1 := PackedInt32Array()      # 操作数 1（AND 用）
var seg_n := PackedInt32Array()         # AND 的操作数个数
var seg_off := PackedInt32Array()       # AND 3+ 输入时在 src_flat 里的偏移
var seg_const := PackedInt32Array()     # CONST 的值

# ========== 寄存器锁存（时序元件） ==========
# 寄存器 Q 是「外部输入」性质：组合求值读它、锁存写它。
# 时序：先跑组合（clk 取本拍值、D 取拍前快照，同拍内所有寄存器同时采样），
# 锁存后 Q 若真的变了，本拍立刻用新 Q 再跑一遍组合把新电平传给下游。
# ⚠ 早期实现让新 Q 隔 2 拍才参与组合，表现为「寄存器贴图已经变了、灯泡却要等
#   下一次信号变化才亮」；同一拍传播才是用户期望的时序语义。
var lock_q_slot := PackedInt32Array()
var lock_clk_slot := PackedInt32Array()
var lock_d_slot := PackedInt32Array()
var lock_state := PackedInt32Array()
# 拍前值快照缓冲（latch 用 D 的拍前值）。复用同一块，避免每拍 duplicate() 分配。
var prev_buf := PackedInt32Array()


# ========== 原生求值器（SPEC-06，GDExtension） ==========
# 存在时 evaluate() 直接调用 C++ 实现；不存在时回退到下面的 GDScript 实现。
# 两者语义逐位一致，由 test_expr_parity.gd 把关。
var native_eval = null
# 本程序是否正在使用原生求值器
var using_native: bool = false


# 尝试挂接原生求值器（执行表已构建完成后调用）
func attach_native() -> bool:
	native_eval = null
	using_native = false
	if not ClassDB.class_exists("SWExprEval"):
		return false
	var ev = ClassDB.instantiate("SWExprEval")
	if ev == null:
		return false
	# 打包成单个 Array 传给 upload：见 SWExprEval::upload 的注释，
	# 13 个 packed array 形参会导致栈破坏（signal 11）。
	var tables: Array = [
		op_seg_kind, op_seg_start, op_seg_count,
		seg_dst, seg_src0, seg_src1,
		seg_n, seg_off, seg_const,
		src_flat, extra_start, extra_dst,
		primary, expr_count,
	]
	if not ev.upload(tables):
		return false
	native_eval = ev
	using_native = true
	return true


# 值的存放空间大小 = 原 slot 数
func value_space() -> int:
	return slot_count


# 一拍完整求值（组合 → 锁存 → Q 变化后同拍再传播）。
#
# ⚠ 返回**结果值数组**：调用方必须使用返回值，而不是原来传进来的 vals。
#   原因：原生路径求值发生在 C++ 内部缓冲里，结果以新数组返回；
#   未走原生时直接返回传进来的 vals（同一块）。
func tick(vals: PackedInt32Array) -> PackedInt32Array:
	var prev := vals.duplicate()
	apply_q(vals)
	var out := _eval(vals)
	# 帧边界锁存：clk 读本拍值、D 读拍前快照（同拍内所有寄存器同时采样）
	if latch(out, prev):
		# Q 本拍真的翻了 → 立刻用新 Q 再算一遍组合，下游（LED/连线）当拍即亮
		apply_q(out)
		out = _eval(out)
	return out


# 跑一遍组合求值（原生可用则走原生），返回承载结果的数组
func _eval(vals: PackedInt32Array) -> PackedInt32Array:
	if using_native and native_eval != null:
		native_eval.set_values(vals)
		native_eval.evaluate()
		return native_eval.get_values()
	evaluate(vals)
	return vals


# 每拍执行（热路径，实测占全部求值时间的 92%）。
#
# 调度方式：**按 op 分段的多循环**（实测比「单循环 + switch」快 ~14%：
#   GDScript 里 for-range 紧凑循环的迭代器开销远小于 while + 多路分支）。
#   段数在编译期已尽量合并（见 SWExprBuilder._build_segments）。
func evaluate(vals: PackedInt32Array) -> void:
	var starts := op_seg_start
	var counts := op_seg_count
	var kinds := op_seg_kind
	var total: int = kinds.size()
	var d_all := seg_dst
	var s0_all := seg_src0
	var s1_all := seg_src1
	var n_all := seg_n
	var off_all := seg_off
	var c_all := seg_const
	var flat_all := src_flat
	for seg in total:
		var kind: int = kinds[seg]
		var base: int = starts[seg]
		var end: int = base + counts[seg]
		if kind == EX_NOT:
			for k in range(base, end):
				vals[d_all[k]] = 1 - vals[s0_all[k]]
		elif kind == EX_AND:
			for k in range(base, end):
				var ln: int = n_all[k]
				if ln == 2:
					vals[d_all[k]] = vals[s0_all[k]] & vals[s1_all[k]]
				elif ln == 1:
					vals[d_all[k]] = vals[s0_all[k]]
				elif ln == 0:
					#空输入 AND = 常量 0（悬空 net 为低电平），与原生一致
					vals[d_all[k]] = 0
				else:
					#3 个及以上驱动者的线与（编译器允许 ≤4，超了折叠链）：
					#操作数从 seg_off 起在 src_flat 里连续存放，必须全量累与。
					#⚠ 这里曾经只有 ln==2 / ln==1 两支，其余一律写 0 —— 回退路径上
					#  三四个开关汇到同一根线上会恒为低电平（原生 C++ 与 SWSignalEvalCPU
					#  都是全量累与，只有 GDScript 这支漏了）。
					var off: int = off_all[k]
					var acc: int = 1
					for j in ln:
						acc &= vals[flat_all[off + j]]
					vals[d_all[k]] = acc
		elif kind == EX_ALIAS:
			for k in range(base, end):
				vals[d_all[k]] = vals[s0_all[k]]
		else:   # EX_CONST
			for k in range(base, end):
				vals[d_all[k]] = c_all[k]
	# 附加写目标（同一表达式服务多个 slot）
	if extra_dst.size() > 0:
		var xd := extra_dst
		var xs := extra_start
		for i in expr_count:
			var s: int = xs[i]
			var e: int = xs[i + 1]
			if s == e:
				continue
			var v2: int = vals[primary[i]]
			for j in range(s, e):
				vals[xd[j]] = v2


# 组合求值前调用：把已锁存的 Q 写进 vals（组合读到的就是它）
func apply_q(vals: PackedInt32Array) -> void:
	var rn := lock_q_slot.size()
	if rn == 0:
		return
	var st := lock_state
	for i in rn:
		vals[lock_q_slot[i]] = st[i * 2]


# 每拍锁存：组合求值之后调用，返回是否有寄存器 Q 真的变了。
# 采样只做一次：同拍内所有寄存器都读拍前快照 prev，保证同步采样。
func latch(vals: PackedInt32Array, prev: PackedInt32Array) -> bool:
	var rn := lock_q_slot.size()
	if rn == 0:
		return false
	var st := lock_state
	var changed := false
	for i in rn:
		var last_clk: int = st[i * 2 + 1]
		var clk_slot: int = lock_clk_slot[i]
		var d_slot: int = lock_d_slot[i]
		var cur_clk: int = 0 if clk_slot < 0 else vals[clk_slot]
		var cur_d: int = 0 if d_slot < 0 else prev[d_slot]
		if last_clk < 0:
			st[i * 2 + 1] = cur_clk
		elif last_clk == 0 and cur_clk == 1:
			if st[i * 2] != cur_d:
				changed = true
			st[i * 2] = cur_d
			st[i * 2 + 1] = cur_clk
		else:
			st[i * 2 + 1] = cur_clk
	return changed


func reg_count() -> int:
	return lock_q_slot.size()


# 读寄存器锁存状态（q, last_clk 交替，stride 2）。
# 热路径用：返回**内部缓冲的复用副本**，避免每拍 duplicate()。
# 调用方只读不改，且必须在下一拍 evaluate 之前用完。
var lock_state_view := PackedInt32Array()

func lock_state_ref() -> PackedInt32Array:
	if lock_q_slot.is_empty():
		return EMPTY_ARR
	lock_state_view = lock_state_view.duplicate() if lock_state_view.size() != lock_state.size() \
			else lock_state_view
	for i in lock_state.size():
		lock_state_view[i] = lock_state[i]
	return lock_state_view

static var EMPTY_ARR := PackedInt32Array()


func read_lock_state() -> PackedInt32Array:
	return lock_state.duplicate()


func set_lock_state(q: PackedInt32Array, last_clk: PackedInt32Array) -> void:
	var n := lock_q_slot.size()
	lock_state.resize(n * 2)
	for i in n:
		lock_state[i * 2] = q[i] if i < q.size() else 0
		lock_state[i * 2 + 1] = last_clk[i] if i < last_clk.size() else -1


# 诊断：可读的表达式树（测试断言 / 调试输出）
func describe(expr_idx: int, depth: int = 6) -> String:
	if expr_idx < 0 or expr_idx >= expr_count:
		return "?"
	var op: int = ops[expr_idx]
	var name := "?"
	match op:
		EX_NOT: name = "NOT"
		EX_AND: name = "AND"
		EX_ALIAS: name = "ALIAS"
		EX_CONST: name = "CONST(%d)" % const_val[expr_idx]
	var parts := PackedStringArray()
	var off: int = src_offs[expr_idx]
	var ln: int = src_lens[expr_idx]
	for k in ln:
		parts.append("s%d" % src_flat[off + k])
	return "%s[%s]" % [name, ",".join(parts)]
