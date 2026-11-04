extends GutTest
# 唯一表达式 DAG 的 GDScript 求值实现（原生 GDExtension 不可用时的回退路径）：
#   EX_AND 必须按 seg_n 里的真实操作数个数全量累与。历史实现只认得 1 / 2 个输入，
#   其余一律写 0 —— 回退路径上「3~4 个驱动者汇到同一根 net」会恒为低电平，
#   而原生 C++（sw_expr_eval.cpp）与 SWSignalEvalCPU 都是全量累与。
#   这里直接构造 gate 表，不拉起游戏场景，也不依赖原生扩展是否加载成功。
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_expr_fallback -gexit

# 造一个「fan_in 个源 → 一根 net」的最小电路：slot0 = net，slot1.. = 各驱动源。
# 正是 SWGateCompiler 对多驱动 net 的写法（一条 OP_AND 归并全部驱动者）。
func _build(fan_in: int, native: bool = false) -> SWExprProgram:
	var prog := SWGateProgram.new()
	prog.slot_count = fan_in + 1
	var g := PackedInt32Array()
	for i in fan_in:
		g.append(SWGateProgram.OP_INPUT)
		g.append(1 + i)
		for _k in 6:
			g.append(0)
	g.append(SWGateProgram.OP_AND)
	g.append(0)                      # dst：net0
	g.append(1)                      # level（拓扑层）
	g.append(fan_in)                 # src_count
	for i in 4:
		g.append(1 + i if i < fan_in else 0)
	prog.gates = g
	prog.gate_count = fan_in + 1
	var builder := SWExprBuilder.new()
	builder.enable_native = native    # false：只验 GDScript 实现，不挂原生
	return builder.build(prog)

# 把源电平写进 slot1..，跑一遍组合求值，返回 net0 的电平
func _net_level(ep: SWExprProgram, bits: Array) -> int:
	var vals := PackedInt32Array()
	vals.resize(ep.value_space())
	vals.fill(0)
	for i in bits.size():
		vals[1 + i] = int(bits[i])
	ep.evaluate(vals)
	return vals[0]

func test_single_input_passes_through() -> void:
	var ep := _build(1)
	assert_eq(_net_level(ep, [1]), 1)
	assert_eq(_net_level(ep, [0]), 0)

func test_two_inputs_still_and() -> void:
	var ep := _build(2)
	assert_eq(_net_level(ep, [1, 1]), 1, "两个驱动者全高才高")
	assert_eq(_net_level(ep, [1, 0]), 0)

func test_three_inputs_are_all_anded() -> void:
	var ep := _build(3)
	assert_eq(_net_level(ep, [1, 1, 1]), 1, "3 个驱动者全高才高")
	assert_eq(_net_level(ep, [1, 0, 1]), 0, "缺一个就得低（旧实现会把整根 net 写死成 0）")
	assert_eq(_net_level(ep, [0, 0, 0]), 0)

func test_four_inputs_are_all_anded() -> void:
	var ep := _build(4)
	assert_eq(_net_level(ep, [1, 1, 1, 1]), 1, "4 个驱动者全高才高（编译器允许的上限）")
	assert_eq(_net_level(ep, [1, 1, 1, 0]), 0)
	assert_eq(_net_level(ep, [0, 1, 1, 1]), 0)

# 与原生实现逐位对拍：同一份 gate 表交给两套后端，所有输入组合的结果必须一致。
# 原生扩展没加载成功时这条自动跳过（自己与自己比没有意义）。
func test_fallback_matches_native_when_available() -> void:
	var compared := 0
	for fan_in in [1, 2, 3, 4]:
		var gd_ep := _build(fan_in)
		var nat_ep := _build(fan_in, true)
		if not nat_ep.using_native:
			continue
		for mask in range(1 << fan_in):
			var src := PackedInt32Array()
			src.resize(gd_ep.value_space())
			src.fill(0)
			for i in fan_in:
				src[1 + i] = (mask >> i) & 1
			var a := src.duplicate()
			gd_ep.evaluate(a)
			var b: PackedInt32Array = nat_ep._eval(src.duplicate())
			assert_eq(a[0], b[0], "%d 个驱动者、mask=%d：GDScript 回退与原生不一致" % [fan_in, mask])
			compared += 1
	if compared == 0:
		pass_test("环境里没有原生求值扩展，跳过与原生对拍")
