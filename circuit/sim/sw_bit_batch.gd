class_name SWBitBatch extends RefCounted

# 位平面（bit-slice）批量求值：在**同一份 SWExprProgram** 上同时跑 N 个互不相干的实例。
#
# 为什么需要它：几十台机器人挂电路时每台每拍单独 tick 已压到 0.13ms/台，
# 但那是「台数 × 每台成本」线性增长，1 万台一拍要 1.2 秒。
# 这些机器人跑的是同一份网表，只有 clk / detect_res 这些**输入**不同（寄存器状态也不同），
# 于是把「一个 slot 的 1/0」压成「一个 64 位字的第 b 位 = 第 b 台」，
# 一条表达式一次位运算就同时算完 64 台 —— 688 条表达式 × 10000 台实测 4.6ms/遍。
#
# ⚠ 为什么建在 SWExprProgram 上而不是 gate 表：
#   生产默认走表达式后端（SWLogicRuntime._expr_active），实测两者在计数器电路上
#   多拍之后会分叉（gate 表 245 个 slot 与表达式后端不一致）。批量路径必须与
#   玩家实际看到的那条后端逐位一致，否则就是「机器人在多人场景里行为不一样」。
#
# 语义与 SWExprProgram.tick/apply_q/latch 严格一致（test_robot_bit_batch 逐位对拍）：
# - 组合：按编译期分好的 op 段（NOT / AND / ALIAS / CONST）逐字位运算；
# - 寄存器：clk 读本拍、D 读拍前快照；首拍只对齐不采样；上升沿（0→1）采样 q = D；
# - Q 本拍真的翻了就再算一遍组合，下游当拍即见新电平。

var expr: SWExprProgram = null
# 已分配容量对应的字数（每 slot 占 words 个字）
var words: int = 0
var slot_count: int = 0
# ⚠ 为什么用**单块缓冲原地求值**，而不是 ping-pong：
#   电路里的反馈环在拓扑序里被切开，环上节点读到的就是「自己上一拍的旧值」。
#   原地求值天然就是这个语义（没被本拍写到的 slot 保留上一拍结果）；
#   换成双缓冲后环上读到的是上上拍，实跪 47 个 slot 立即分叉。
var buf := PackedInt64Array()   # 单缓冲：本拍工作区，也是「上一拍结果」
var d_snap := PackedInt64Array() # 锁存用的 D 拍前快照（每寄存器 words 个字）
# 每寄存器三张平面：Q、上一次 clk、是否已对齐（-1 = 全部实例都已对齐）
var reg_q := PackedInt64Array()
var reg_clk := PackedInt64Array()
var reg_valid := PackedInt64Array()


func setup(e: SWExprProgram, capacity: int) -> void:
	expr = e
	words = 0
	buf = PackedInt64Array()
	d_snap = PackedInt64Array()
	reg_q = PackedInt64Array()
	reg_clk = PackedInt64Array()
	reg_valid = PackedInt64Array()
	slot_count = 0 if e == null else e.value_space()
	ensure_capacity(capacity)


func is_usable() -> bool:
	return expr != null and slot_count > 0


# 扩容（保留已有个例的寄存器状态）：台数只增不减时走这里
func ensure_capacity(capacity: int) -> void:
	var w: int = (maxi(capacity, 1) + 63) >> 6
	if w <= words:
		return
	var old_words: int = words
	var nbuf := PackedInt64Array()
	nbuf.resize(slot_count * w)
	if old_words > 0:
		for s in slot_count:
			var src: int = s * old_words
			var dst: int = s * w
			for k in old_words:
				nbuf[dst + k] = buf[src + k]
	buf = nbuf
	var rn: int = expr.reg_count() if expr != null else 0
	var nq := PackedInt64Array()
	nq.resize(rn * w)
	var nclk := PackedInt64Array()
	nclk.resize(rn * w)
	var nvalid := PackedInt64Array()
	nvalid.resize(rn * w)
	var ndsnap := PackedInt64Array()
	ndsnap.resize(rn * w)
	if old_words > 0:
		for i in rn:
			for k in old_words:
				nq[i * w + k] = reg_q[i * old_words + k]
				nclk[i * w + k] = reg_clk[i * old_words + k]
				nvalid[i * w + k] = reg_valid[i * old_words + k]
				ndsnap[i * w + k] = d_snap[i * old_words + k]
	reg_q = nq
	reg_clk = nclk
	reg_valid = nvalid
	d_snap = ndsnap
	words = w


# 清掉一台（实例位）的全部状态：删机器人后它那个 bit 变成「无输入无输出」的空洞。
# 槽位不回收（回收要搬动上万台的状态），空洞只在 64 位字里占一 bit，忽略不计
func clear_bit(bit: int) -> void:
	if words <= 0:
		return
	var o: int = bit >> 6
	var m: int = 1 << (bit & 63)
	var im: int = ~m
	for s in slot_count:
		var base: int = s * words + o
		buf[base] = buf[base] & im
	var rn: int = expr.reg_count() if expr != null else 0
	for i in rn:
		var k: int = i * words + o
		reg_q[k] = reg_q[k] & im
		reg_clk[k] = reg_clk[k] & im
		reg_valid[k] = reg_valid[k] & im


func reset_all() -> void:
	buf.fill(0)
	d_snap.fill(0)
	reg_q.fill(0)
	reg_clk.fill(0)
	reg_valid.fill(0)


# 写一个源 slot 的第 bit 位（clk / detect_res 这类来自机器人自身的输入）
func write_slot_bit(slot: int, bit: int, level: int) -> void:
	if slot < 0 or slot >= slot_count or words <= 0:
		return
	var o: int = slot * words + (bit >> 6)
	var m: int = 1 << (bit & 63)
	if level != 0:
		buf[o] = buf[o] | m
	else:
		buf[o] = buf[o] & ~m


# 读一个 slot 的第 bit 位（读的是本拍结果）
func read_slot_bit(slot: int, bit: int) -> int:
	if slot < 0 or slot >= slot_count or words <= 0:
		return 0
	return int((buf[slot * words + (bit >> 6)] >> (bit & 63)) & 1)


# 一拍：D 快照 → Q 写回 → 组合 → 锁存（Q 翻了就再跑一遍组合）
func tick() -> void:
	if expr == null or words <= 0:
		return
	_snap_d()
	_apply_q()
	_eval()
	if _latch():
		_apply_q()
		_eval()


# 锁存的 D 要读「拍前值」：组合会把 D 所在 slot 覆盖掉，所以先拍一张
func _snap_d() -> void:
	var d_slots := expr.lock_d_slot
	var w: int = words
	for i in d_slots.size():
		var s: int = d_slots[i]
		if s < 0:
			for x in w:
				d_snap[i * w + x] = 0
			continue
		for x in w:
			d_snap[i * w + x] = buf[s * w + x]


# 组合求值：按 op 段逐字位运算。
# ⚠ 这里**不能**把 buf 取成局部变量：PackedInt64Array 是写时复制，
#   局部别名一写就整块复制（1 万台 = 880KB × 每段），必须直接索引成员
func _eval() -> void:
	var starts := expr.op_seg_start
	var counts := expr.op_seg_count
	var kinds := expr.op_seg_kind
	var d_all := expr.seg_dst
	var s0_all := expr.seg_src0
	var s1_all := expr.seg_src1
	var n_all := expr.seg_n
	var off_all := expr.seg_off
	var c_all := expr.seg_const
	var flat_all := expr.src_flat
	var w: int = words
	for seg in kinds.size():
		var kind: int = kinds[seg]
		var base: int = starts[seg]
		var end: int = base + counts[seg]
		if kind == SWExprProgram.EX_NOT:
			for k in range(base, end):
				var d: int = d_all[k] * w
				var s0: int = s0_all[k] * w
				for x in w:
					buf[d + x] = ~buf[s0 + x]
		elif kind == SWExprProgram.EX_AND:
			for k in range(base, end):
				var d: int = d_all[k] * w
				var ln: int = n_all[k]
				if ln == 2:
					var s0: int = s0_all[k] * w
					var s1: int = s1_all[k] * w
					for x in w:
						buf[d + x] = buf[s0 + x] & buf[s1 + x]
				elif ln == 1:
					var s0: int = s0_all[k] * w
					for x in w:
						buf[d + x] = buf[s0 + x]
				elif ln == 0:
					for x in w:
						buf[d + x] = 0
				else:
					var off: int = off_all[k]
					var s0: int = flat_all[off] * w
					for x in w:
						buf[d + x] = buf[s0 + x]
					for j in range(1, ln):
						var sp: int = flat_all[off + j] * w
						for x in w:
							buf[d + x] = buf[d + x] & buf[sp + x]
		elif kind == SWExprProgram.EX_ALIAS:
			for k in range(base, end):
				var d: int = d_all[k] * w
				var s0: int = s0_all[k] * w
				for x in w:
					buf[d + x] = buf[s0 + x]
		else:   # EX_CONST
			for k in range(base, end):
				var d: int = d_all[k] * w
				var v: int = 0
				if c_all[k] != 0:
					v = -1
				for x in w:
					buf[d + x] = v
	# 附加写目标：同一表达式服务的其余 slot 跟着主目标走
	var extra_n: int = expr.extra_dst.size()
	if extra_n > 0:
		var xd := expr.extra_dst
		var xs := expr.extra_start
		var pri := expr.primary
		for i in expr.expr_count:
			var s: int = xs[i]
			var e2: int = xs[i + 1]
			if s == e2:
				continue
			var p: int = pri[i] * w
			for j in range(s, e2):
				var dd: int = xd[j] * w
				for x in w:
					buf[dd + x] = buf[p + x]


# 把已锁存的 Q 写进工作区（组合读到的就是它）
func _apply_q() -> void:
	var q_slots := expr.lock_q_slot
	var w: int = words
	for i in q_slots.size():
		var d: int = q_slots[i] * w
		var s: int = i * w
		for x in w:
			buf[d + x] = reg_q[s + x]


# 锁存：clk 读本拍（buf），D 读拍前快照（d_snap）。返回是否有寄存器 Q 真的翻了
func _latch() -> bool:
	var q_slots := expr.lock_q_slot
	var clk_slots := expr.lock_clk_slot
	var d_slots := expr.lock_d_slot
	var w: int = words
	var changed: bool = false
	for i in q_slots.size():
		var clk_slot: int = clk_slots[i]
		var d_slot: int = d_slots[i]
		var base: int = i * w
		for x in w:
			var clk_v: int = 0 if clk_slot < 0 else buf[clk_slot * w + x]
			# ⚠ d_snap 是按**寄存器序号**紧凑存的（每寄存器 w 个字），不是按 slot 编号
			var d_v: int = 0 if d_slot < 0 else d_snap[i * w + x]
			# 首拍（valid = 0）只对齐 last_clk，不采样
			var rise: int = reg_valid[base + x] & ~reg_clk[base + x] & clk_v
			var q_old: int = reg_q[base + x]
			var q_new: int = (q_old & ~rise) | (d_v & rise)
			if q_new != q_old:
				changed = true
			reg_q[base + x] = q_new
			reg_clk[base + x] = clk_v
			reg_valid[base + x] = -1
	return changed


# 寄存器 Q 电平（排障/对拍用）
func reg_bit(i: int, bit: int) -> int:
	if expr == null or i < 0 or i >= expr.reg_count() or words <= 0:
		return 0
	return int((reg_q[i * words + (bit >> 6)] >> (bit & 63)) & 1)
