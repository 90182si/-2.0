extends GutTest
# gate 表化简器（SWGateOptimizer）契约：
#   1. slot 空间、gate 条数、每条 dst / 拓扑层一律不变（slot 编号是回填契约，
#      删 slot 或重排会让 net_slots / led_group_src_flat / gate_out_slots 全指向错的电平）；
#   2. NOT(NOT(x)) → ALIAS(x)（用户点名的双非门抵消）；
#   3. AND(x) → ALIAS(x)（单输入线与就是直通）、AND(a, a) → AND(a)（去重）；
#   4. 线与里出现恒 0 项 → AND()（常量 0）；
#   5. 化简前后用同一份输入跑 gate 引擎，每个 slot 的电平必须逐位一致；
#   6. 反馈环上的 gate 一律不动（环上的中间态是计数器时序的一部分）；
#   7. 折到不动点：一轮下来零改动才停，已简化的程序再化简必须一条不改。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix=test_gate_optimizer -gexit

const OPT := preload("res://circuit/sw_gate_optimizer.gd")
# 只用它的常量（STRIDE / OP_*）；class_name 不能当常量表达式，统一 preload
const P := preload("res://circuit/sw_gate_program.gd")

#手搓一份 gate 表。gates 的每一项是 [op, dst, level, srcs]，且必须已按 level 升序排好。
func _prog(slot_count: int, gates: Array, inputs: Array = []) -> SWGateProgram:
	var p := SWGateProgram.new()
	p.slot_count = slot_count
	p.gate_count = gates.size()
	p.gates.resize(gates.size() * P.STRIDE)
	var level_counts: Dictionary = {}
	for i in gates.size():
		var g: Array = gates[i]
		var base: int = i * P.STRIDE
		p.gates[base + 0] = g[0]
		p.gates[base + 1] = g[1]
		p.gates[base + 2] = g[2]
		var srcs: Array = g[3]
		p.gates[base + 3] = srcs.size()
		for k in srcs.size():
			p.gates[base + 4 + k] = srcs[k]
		level_counts[g[2]] = int(level_counts.get(g[2], 0)) + 1
	var max_level := 0
	for lv in level_counts:
		max_level = maxi(max_level, int(lv))
	p.level_count = max_level + 1
	p.level_starts.resize(p.level_count)
	p.level_starts.fill(-1)
	p.level_counts.resize(p.level_count)
	p.level_counts.fill(0)
	var cursor := 0
	for lv in p.level_count:
		if level_counts.has(lv):
			p.level_starts[lv] = cursor
			p.level_counts[lv] = level_counts[lv]
			cursor += int(level_counts[lv])
	p.loop_slot_flags.resize(slot_count)
	p.loop_slot_flags.fill(0)
	for s in inputs:
		p.input_slots.append(s)
	return p

func _ops(prog: SWGateProgram) -> Array:
	var out: Array = []
	for gi in prog.gate_count:
		var base: int = gi * P.STRIDE
		out.append([prog.gates[base], prog.gates[base + 1], prog.gates[base + 2],
			prog.gate_srcs(gi)])
	return out

#用 gate 引擎跑一遍，取每个 slot 的电平（readback 返回本拍结果）
func _run(prog: SWGateProgram, inputs: PackedInt32Array) -> PackedInt32Array:
	var e := SWSignalEvalCPU.new()
	e.setup(prog)
	e.write_sources(inputs)
	e.evaluate()
	return e.readback().duplicate()

# 1) 双非门抵消：NOT(NOT(x)) 的第二级变成直通
func test_not_not_becomes_alias() -> void:
	var p := _prog(3, [
		[P.OP_NOT, 1, 1, [0]],
		[P.OP_NOT, 2, 2, [1]],
	], [0])
	var opt = OPT.new()
	var s: SWGateProgram = opt.optimize(p)
	var got := _ops(s)
	assert_eq(got[0][0], P.OP_NOT, "第一级非门照旧（那根 net 对外可观测）")
	assert_eq(got[1][0], P.OP_ALIAS, "NOT(NOT(x)) 的第二级应当化简成直通")
	assert_eq(got[1][3], [0], "直通目标要一路穿到最初的源")
	assert_eq(opt.optimized_gates, 1, "只改写了第二条 gate")

# 2) 单输入线与直通 + 去重
func test_and_single_source_and_dedup() -> void:
	var p := _prog(4, [
		[P.OP_AND, 2, 1, [0]],
		[P.OP_AND, 3, 1, [0, 0, 1]],
	], [0, 1])
	var s: SWGateProgram = OPT.new().optimize(p)
	var got := _ops(s)
	assert_eq(got[0][0], P.OP_ALIAS, "单输入线与就是直通")
	assert_eq(got[0][3], [0])
	assert_eq(got[1][0], P.OP_AND, "多输入还是与门")
	assert_eq(got[1][3], [0, 1], "AND(a, a, b) 去重成 AND(a, b)")

# 3) 线与里出现恒 0 项 → 整体常量 0（空输入 AND）
func test_and_with_zero_term_is_const_zero() -> void:
	var p := _prog(3, [
		[P.OP_AND, 1, 1, []],
		[P.OP_AND, 2, 2, [0, 1]],
	], [0])
	var s: SWGateProgram = OPT.new().optimize(p)
	var got := _ops(s)
	assert_eq(got[1][0], P.OP_AND)
	assert_eq(got[1][3], [], "含恒 0 项的线与整体恒 0")

# 4) slot 空间 / gate 条数 / dst / 拓扑层一律不变
func test_slot_space_and_levels_are_preserved() -> void:
	var p := _prog(5, [
		[P.OP_NOT, 1, 1, [0]],
		[P.OP_NOT, 2, 2, [1]],
		[P.OP_AND, 3, 3, [2]],
		[P.OP_AND, 4, 4, [3, 1]],
	], [0])
	p.level_starts = PackedInt32Array([-1, 0, 1, 2, 3])
	p.level_counts = PackedInt32Array([0, 1, 1, 1, 1])
	var s: SWGateProgram = OPT.new().optimize(p)
	assert_eq(s.slot_count, p.slot_count, "slot 空间必须原样")
	assert_eq(s.gate_count, p.gate_count, "gate 条数必须原样")
	assert_eq(s.level_count, p.level_count, "层数必须原样")
	assert_eq(s.level_starts, p.level_starts, "层区间表必须原样")
	assert_eq(s.level_counts, p.level_counts, "层 gate 计数必须原样")
	for gi in p.gate_count:
		var base: int = gi * P.STRIDE
		assert_eq(s.gates[base + 1], p.gates[base + 1], "第 %d 条 gate 的 dst 不能变" % gi)
		assert_eq(s.gates[base + 2], p.gates[base + 2], "第 %d 条 gate 的拓扑层不能变" % gi)

# 5) 化简前后逐位等价：同一份输入，每个 slot 的电平静一致
func test_evaluation_stays_equivalent() -> void:
	var p := _prog(7, [
		[P.OP_NOT, 2, 1, [0]],
		[P.OP_AND, 5, 1, [0, 0, 1]],
		[P.OP_NOT, 3, 2, [2]],
		[P.OP_AND, 4, 3, [3]],
		[P.OP_AND, 6, 4, [4, 3]],
	], [0, 1])
	var s: SWGateProgram = OPT.new().optimize(p)
	var cases := [
		PackedInt32Array([0, 0]),
		PackedInt32Array([1, 0]),
		PackedInt32Array([0, 1]),
		PackedInt32Array([1, 1]),
	]
	for inp in cases:
		var a := _run(p, inp)
		var b := _run(s, inp)
		assert_eq(b, a, "输入 %s 下化简前后必须逐位一致" % str(inp))

# 6) 反馈环上的 gate 一律不动
func test_loop_slots_are_left_alone() -> void:
	var p := _prog(3, [
		[P.OP_NOT, 1, 1, [2]],
		[P.OP_NOT, 2, 2, [1]],
	], [])
	p.loop_slot_flags = PackedByteArray([0, 1, 1])
	var opt = OPT.new()
	var s: SWGateProgram = opt.optimize(p)
	assert_eq(_ops(s), _ops(p), "环上的两条非门不能被抵消（那是时序的一部分）")
	assert_eq(opt.optimized_gates, 0)

# 7) 环上标记来自编译器：compile 之后 loop_slot_flags 的长度与 slot 空间一致
func test_compiler_publishes_loop_flags() -> void:
	var prog: SWGateProgram = SWGateCompiler.new().compile([])
	assert_eq(prog.slot_count, 0, "空电路没有 slot")
	assert_eq(prog.loop_slot_flags.size(), 0, "没有 slot 就没有环标记")

# 9) 折到不动点：再跑一次化简器应当一条都不改（简化量为 0）
func test_optimizer_reaches_fixed_point() -> void:
	var p := _prog(6, [
		[P.OP_NOT, 1, 1, [0]],
		[P.OP_NOT, 2, 2, [1]],
		[P.OP_NOT, 3, 3, [2]],
		[P.OP_AND, 4, 4, [3, 3]],
		[P.OP_AND, 5, 5, [4]],
	], [0])
	var opt = OPT.new()
	var s: SWGateProgram = opt.optimize(p)
	var got := _ops(s)
	assert_eq(got[0][0], P.OP_NOT, "第一层非门保留（那根 net 对外可观测）")
	assert_eq(got[1][0], P.OP_ALIAS, "第二层 NOT(NOT) 直通")
	assert_eq(got[1][3], [0], "直通要穿到最初的源")
	assert_eq(got[2][3], [0], "第三层继续穿到源，只剩一层取反")
	assert_eq(got[2][0], P.OP_NOT, "三层取反只能消两层")
	assert_eq(got[4][0], P.OP_ALIAS, "末尾单输入与门直通")
	assert_gt(opt.passes, 0, "至少要跑一轮有改动的迭代")
	# 不动点：已简化过的程序再化简一次必须零改动
	var again = OPT.new()
	var s2: SWGateProgram = again.optimize(s)
	assert_eq(_ops(s2), got, "已到不动点：再化简一次结果不变")
	assert_eq(again.optimized_gates, 0, "重新化简的简化量必须是 0")
	assert_eq(again.passes, 0, "零改动就一轮都不算")

# 10) 不等层排好顺序的 gate 表也要折到底（不依赖遍历顺序）
func test_optimizer_is_order_independent() -> void:
	# 故意把高层的 gate 放前面：g0 处理时它引用的 slot2 还没被化简，
	# 只能等下一轮才能穿到最初的源——不动点迭代的保底契约
	var p := _prog(4, [
		[P.OP_AND, 1, 3, [2]],
		[P.OP_NOT, 2, 2, [3]],
		[P.OP_NOT, 3, 1, [0]],
	], [0])
	var opt = OPT.new()
	var s: SWGateProgram = opt.optimize(p)
	var got := _ops(s)
	assert_eq(got[2][0], P.OP_NOT, "第一层非门保留（那根 net 对外可观测）")
	assert_eq(got[1][0], P.OP_ALIAS, "NOT(NOT(x)) 抵消成直通")
	assert_eq(got[1][3], [0], "直通一路指到最初的源")
	assert_eq(got[0][0], P.OP_ALIAS, "引用它的单输入与门也跟着直通")
	assert_eq(got[0][3], [0], "第二轮才能穿到源（证明真的多跑了一轮）")
	assert_gt(opt.passes, 1, "这个表要两轮以上才能折到底")
	var again = OPT.new()
	again.optimize(s)
	assert_eq(again.optimized_gates, 0, "折到不动点后没有可改的了")

# 8) 随机无环网表的模糊对拍：化简只能改变「怎么算」，不能改变「算出什么」
func test_random_dags_stay_equivalent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261103
	var n_in := 3
	var n_slots := 12
	for case_i in 15:
		# src 只取比 dst 小的 slot → 天然无环，优化器可以全力化简
		var gates: Array = []
		for dst in range(n_in, n_slots):
			var cnt: int = rng.randi_range(0, 3)
			var srcs: Array = []
			for _k in cnt:
				srcs.append(rng.randi_range(0, dst - 1))
			var op: int = P.OP_NOT if (cnt == 1 and rng.randf() < 0.35) else P.OP_AND
			gates.append([op, dst, dst - n_in + 1, srcs])
		var p := _prog(n_slots, gates, [0, 1, 2])
		var s: SWGateProgram = OPT.new().optimize(p)
		for t in 4:
			var inp := PackedInt32Array()
			for _i in n_in:
				inp.append(rng.randi_range(0, 1))
			assert_eq(_run(s, inp), _run(p, inp),
				"第 %d 个随机电路的第 %d 组输入化简前后不一致" % [case_i, t])
