class_name SWLogicRuntime extends RefCounted

# ==========================================================================
# 纯逻辑运行时（SimCore S1/S2 落地件）：prog + **自持状态** → 每拍一个结果事件。
#
# 依赖边界（本文件一个实体类名都不出现）：
#   命令入：set_source / set_all_sources / init_reg_state / init_prev / reset
#   结果出：tick() 返回 SWSimResult，同时通过 outputs_changed 广播差分事件
# 也就是说：拿到一个 prog（可以由 SWNetlist 离线编译出来）之后，
# 这条链路可以完全不加载世界、不实例化任何建筑就跑起来（headless / 单测 / 回放）。
#
# 状态全部由本对象持有，跨拍不回读组件：
#   src_levels ：源电平（按 prog.input_slots 序）
#   reg_state  ：stride2 [q, last_clk]（last_clk < 0 = 尚未对齐时钟相位）
#   _prev_*    ：上一拍基线（差分事件用，注意这些**不复用** prog 里的显示缓存，
#                否则纯逻辑跑拍会污染表现层的 led_group_prev / net_prev_bit）
#
# ⚠ slot_vals 是求值引擎内部缓冲的视图（下一拍会被覆盖），需要跨拍保存请 duplicate()。
#    这与 SWCircuitControl._last_slots 的口径一致。
# ==========================================================================

signal outputs_changed(result: SWSimResult)
signal ticked(result: SWSimResult)

var prog: SWGateProgram = null
# 两条求值实现：表达式 DAG（默认，去重后只算唯一表达式）/ 原 gate 表逐层
var engine: SWSignalEvalCPU = null
var expr: SWExprProgram = null
var use_expr_dag: bool = true
var use_native: bool = true

var src_levels := PackedInt32Array()
var slot_vals := PackedInt32Array()
var reg_state := PackedInt32Array()
var tick_count: int = 0

var _expr_active: bool = false
var _expr_vals := PackedInt32Array()
var _prev_nets := PackedInt32Array()
var _prev_groups := PackedInt32Array()
var _prev_reg_q := PackedInt32Array()


# 建立运行时。use_dag = false 时退回原 gate 表引擎（对拍/回退用）。
func setup(p: SWGateProgram, use_dag: bool = true, native: bool = true) -> void:
	prog = p
	use_expr_dag = use_dag
	use_native = native
	engine = SWSignalEvalCPU.new()
	engine.setup(prog)
	src_levels = PackedInt32Array()
	src_levels.resize(prog.input_slots.size())
	src_levels.fill(0)
	slot_vals = PackedInt32Array()
	slot_vals.resize(prog.slot_count)
	slot_vals.fill(0)
	reg_state = PackedInt32Array()
	reg_state.resize(prog.reg_slots.size() * 2)
	reg_state.fill(0)
	for i in prog.reg_slots.size():
		reg_state[i * 2 + 1] = -1
	_expr_active = false
	expr = null
	if use_expr_dag:
		var builder := SWExprBuilder.new()
		builder.enable_native = use_native
		expr = builder.build(prog, [])
		if expr != null:
			_expr_active = true
			_expr_vals = PackedInt32Array()
			_expr_vals.resize(expr.value_space())
			_expr_vals.fill(0)
			_push_reg_state()
	_prev_nets = PackedInt32Array()
	_prev_groups = PackedInt32Array()
	_prev_reg_q = PackedInt32Array()
	tick_count = 0


# 复位到一个干净的上电态（源全 0、寄存器 Q=0 且时钟相位未对齐）
func reset() -> void:
	src_levels.fill(0)
	reg_state.fill(0)
	for i in prog.reg_slots.size():
		reg_state[i * 2 + 1] = -1
	if _expr_active:
		_expr_vals.fill(0)
		_push_reg_state()
	else:
		engine.setup(prog)
	_prev_nets = PackedInt32Array()
	_prev_groups = PackedInt32Array()
	_prev_reg_q = PackedInt32Array()
	tick_count = 0


func src_count() -> int:
	return src_levels.size()


# ===== 命令入口（边界层写输入，唯一改仿真的通道） =====
# i 是「源序号」（与 prog.input_slots 同序）
func set_source(i: int, level: int) -> void:
	if i >= 0 and i < src_levels.size():
		src_levels[i] = 1 if level != 0 else 0


func set_all_sources(vals: PackedInt32Array) -> void:
	for i in mini(vals.size(), src_levels.size()):
		src_levels[i] = 1 if vals[i] != 0 else 0


# 灌入寄存器初值（读档 / 从实体世界接管时用一次；之后状态由本对象自持）
func init_reg_state(q: PackedInt32Array, last_clk: PackedInt32Array) -> void:
	for i in prog.reg_slots.size():
		reg_state[i * 2] = q[i] if i < q.size() else 0
		reg_state[i * 2 + 1] = last_clk[i] if i < last_clk.size() else -1
	_push_reg_state()


# 灌入拍前 slot 基线（读档时让第一拍的寄存器 D 采样与旧世界对齐）
func init_prev(slots: PackedInt32Array) -> void:
	# 表达式路径没有双缓冲：基线就是值数组本身（tick 内部先 apply_q 再算）
	for i in mini(slots.size(), _expr_vals.size()):
		_expr_vals[i] = slots[i]
	if engine != null:
		engine.init_prev(slots)


# ===== 结果入口 =====
func tick() -> SWSimResult:
	if prog == null:
		return SWSimResult.new()
	tick_fast()
	var res := _make_result()
	ticked.emit(res)
	if res.any_change:
		outputs_changed.emit(res)
	return res


# 只推进状态、**不打包差分结果也不广播信号**的一拍。
# 给「一拍要跑很多次 tick」的场合用（机器人侧：每台每拍 2 次 tick，
# 十几条子电路，几十台机器人）。tick() 里的差分打包要扫全部 net / 灯泡组 / 寄存器
# 并新建一个 SWSimResult，在机器人侧没人读，纯浪费。
func tick_fast() -> void:
	if prog == null:
		return
	if _expr_active:
		var ev := _expr_vals
		var ins := prog.input_slots
		var n: int = mini(src_levels.size(), ins.size())
		for i in n:
			ev[ins[i]] = src_levels[i]
		# 原生路径返回的是新数组（结果在 C++ 内部缓冲里算出来的），必须用返回值
		var out_ev := expr.tick(ev)
		_expr_vals = out_ev
		slot_vals = out_ev
		reg_state = expr.lock_state
	else:
		engine.clear_changed()
		engine.write_sources(src_levels)
		engine.evaluate()
		slot_vals = engine.readback()
		reg_state = engine.read_reg_state()
	tick_count += 1


# ===== 只读查询（表现层 / 测试用） =====
func slot_of_net(net_id: int) -> int:
	return int(prog.net_id_to_slot.get(net_id, -1))


func net_level(net_id: int) -> int:
	var s: int = slot_of_net(net_id)
	if s < 0 or s >= slot_vals.size():
		return 0
	return slot_vals[s]


func led_group_level(gi: int) -> int:
	if gi < 0 or gi >= prog.led_group_src_offs.size():
		return 0
	var bit: int = 0
	var off: int = prog.led_group_src_offs[gi]
	var ln: int = prog.led_group_src_lens[gi]
	for k in ln:
		var s: int = prog.led_group_src_flat[off + k]
		if s >= 0 and s < slot_vals.size():
			bit = bit | slot_vals[s]
	return bit


# 单个灯泡的亮灭（灯泡下标 = prog.led_devs / led_comps 的下标）
func led_level(li: int) -> int:
	if li < 0 or li >= prog.led_group_id.size():
		return 0
	return led_group_level(prog.led_group_id[li])


func reg_q_at(i: int) -> int:
	if i < 0 or i * 2 >= reg_state.size():
		return 0
	return reg_state[i * 2]


func describe() -> String:
	return "pure-runtime tick=%d slots=%d srcs=%d regs=%d nets=%d led_groups=%d" % [
		tick_count, prog.slot_count, src_levels.size(), prog.reg_slots.size(),
		prog.net_count, prog.led_group_src_offs.size()
	]


# ===== 内部 =====
func _push_reg_state() -> void:
	var q := PackedInt32Array()
	var lc := PackedInt32Array()
	var rn: int = prog.reg_slots.size()
	for i in rn:
		q.append(reg_state[i * 2])
		lc.append(reg_state[i * 2 + 1])
	if _expr_active and expr != null:
		expr.set_lock_state(q, lc)
	elif engine != null:
		engine.init_reg_state(q, lc)


# 差分打包：net / 灯泡组 / 寄存器各扫一遍，只有真的翻了的才进 changed_* 表。
# 灯泡按「组」比较：同组输入集合相同，亮灭必然同步，一组一次 OR 就够。
func _make_result() -> SWSimResult:
	var res := SWSimResult.new()
	res.tick = tick_count
	res.slot_vals = slot_vals
	res.reg_state = reg_state
	# net：下标 = net 序号，slot 走 net_slots（当前两条编译路径都是 i 对 i，这里只防将来变）
	var net_n: int = prog.net_count
	var n_slots: PackedInt32Array = prog.net_slots
	if _prev_nets.size() != net_n:
		_prev_nets.resize(net_n)
		_prev_nets.fill(-1)
	res.net_levels.resize(net_n)
	var ch_net := PackedInt32Array()
	for i in net_n:
		var s: int = n_slots[i] if i < n_slots.size() else i
		var b: int = slot_vals[s] if s >= 0 and s < slot_vals.size() else 0
		res.net_levels[i] = b
		if _prev_nets[i] != b:
			_prev_nets[i] = b
			ch_net.append(i)
	res.changed_nets = ch_net
	# 灯泡组
	var g_n: int = prog.led_group_src_offs.size()
	if _prev_groups.size() != g_n:
		_prev_groups.resize(g_n)
		_prev_groups.fill(-1)
	res.led_levels.resize(g_n)
	var ch_g := PackedInt32Array()
	for gi in g_n:
		var bit: int = led_group_level(gi)
		res.led_levels[gi] = bit
		if _prev_groups[gi] != bit:
			_prev_groups[gi] = bit
			ch_g.append(gi)
	res.changed_led_groups = ch_g
	# 寄存器 Q
	var rn: int = prog.reg_slots.size()
	if _prev_reg_q.size() != rn:
		_prev_reg_q.resize(rn)
		_prev_reg_q.fill(-1)
	res.reg_q.resize(rn)
	var ch_r := PackedInt32Array()
	for i in rn:
		var q: int = reg_state[i * 2] if i * 2 < reg_state.size() else 0
		res.reg_q[i] = q
		if _prev_reg_q[i] != q:
			_prev_reg_q[i] = q
			ch_r.append(i)
	res.changed_regs = ch_r
	res.any_change = not ch_net.is_empty() or not ch_g.is_empty() or not ch_r.is_empty()
	return res
