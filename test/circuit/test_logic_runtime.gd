extends GutTest
# 纯逻辑运行时（step 2 + step 3）验收：
#   1) 两条求值实现（表达式 DAG / 原 gate 表）在纯逻辑运行时必须逐 slot 一致；
#   2) 灯泡组口径：组结果 = 组内输入 slot 的 OR，组内成员亮灭必然同步；
#   3) **状态自持**：把组件状态直接改掉后，纯逻辑运行结果不得变化（说明它不回读实体）；
#   4) 事件契约：outputs_changed 只在 any_change 的拍触发（差分事件，不是每拍广播）；
#   5) 实体适配：apply_pure_result 把结果镜像回 net 后，net.curSignal 必须与结果一致。
#
# 跑法（单文件，不要跑全量）：
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit \
#         -gprefix=test_logic_runtime -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "ledbug2"

var harness = null


func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)


func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null


# 取一条「有源、有 net」的电路及其 prog。
# 不从 ctrl.circuits 找：那份表是视野内的活动电路表，headless 下可能为空；
# 懒建后端 _cpu_backends 的 key 才是本次真正参与求值的电路对象（与 test_expr_parity 同口径）。
func _pick_circuit() -> Dictionary:
	var ctrl = harness.build_layer.layer_system.circuit_control
	if ctrl == null:
		return {}
	for c in ctrl._cpu_backends.keys():
		if c == null:
			continue
		var p: SWGateProgram = ctrl._compiled_prog(c)
		if p != null and p.net_count > 0 and p.input_slots.size() > 0:
			return {"ctrl": ctrl, "circuit": c, "prog": p}
	return {}


func test_pure_runtime_self_contained() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		pending("存档不存在: " + SAVE_NAME)
		return
	harness.force_load_all_chunks()
	var ctrl0 = harness.build_layer.layer_system.circuit_control
	var guard := 0
	while guard < 3000 and ctrl0 != null and ctrl0._cpu_backends.is_empty():
		guard += 1
		await get_tree().process_frame
	var pick: Dictionary = _pick_circuit()
	if pick.is_empty():
		pending("存档里没有「带源的电路」")
		return
	var ctrl = pick["ctrl"]
	var circuit = pick["circuit"]
	var prog: SWGateProgram = pick["prog"]

	# 1) DAG 与 gate 表两条实现，同一批输入必须逐 slot 一致
	var rt_dag := SWLogicRuntime.new()
	rt_dag.setup(prog, true)
	var rt_raw := SWLogicRuntime.new()
	rt_raw.setup(prog, false)
	assert_eq(rt_dag.slot_vals.size(), prog.slot_count, "运行时值空间必须等于 slot_count")
	for t in 4:
		var srcs := PackedInt32Array()
		for i in prog.input_slots.size():
			srcs.append((t + i) % 2)
		rt_dag.set_all_sources(srcs)
		rt_raw.set_all_sources(srcs)
		var rd: SWSimResult = rt_dag.tick()
		var rr: SWSimResult = rt_raw.tick()
		assert_eq(rd.net_levels, rr.net_levels, "第 %d 拍 net 电平：DAG 与 gate 表不一致" % t)
		assert_eq(rd.led_levels, rr.led_levels, "第 %d 拍 灯泡组：DAG 与 gate 表不一致" % t)
		assert_eq(rd.reg_q, rr.reg_q, "第 %d 拍 寄存器 Q：DAG 与 gate 表不一致" % t)

	# 2) 灯泡组口径：组 = OR(组内输入 slot)，组内成员同步
	var res: SWSimResult = rt_dag.tick()
	for gi in prog.led_group_src_offs.size():
		var want: int = 0
		var off: int = prog.led_group_src_offs[gi]
		var ln: int = prog.led_group_src_lens[gi]
		for k in ln:
			var s: int = prog.led_group_src_flat[off + k]
			want = want | res.slot_vals[s]
		assert_eq(rt_dag.led_group_level(gi), want, "组 %d 亮灭 != 组内输入 slot 的 OR" % gi)
		var mo: int = prog.led_group_mem_offs[gi]
		var mh: int = mo + prog.led_group_mem_lens[gi]
		for mi in range(mo, mh):
			var li: int = prog.led_group_members[mi]
			assert_eq(rt_dag.led_level(li), want, "灯泡 %d 与同组结果不一致（分组口径被破坏）" % li)

	# 3) 状态自持：直接改实体状态，纯逻辑结果必须不变
	var src_before: PackedInt32Array = rt_dag.src_levels.duplicate()
	var twin := SWLogicRuntime.new()
	twin.setup(prog, true)
	var q := PackedInt32Array()
	var lc := PackedInt32Array()
	for i in prog.reg_slots.size():
		q.append(rt_dag.reg_state[i * 2])
		lc.append(rt_dag.reg_state[i * 2 + 1])
	twin.init_reg_state(q, lc)
	twin.set_all_sources(rt_dag.src_levels)
	_mutate_entity_state(prog)
	var res_a: SWSimResult = rt_dag.tick()
	var res_b: SWSimResult = twin.tick()
	assert_eq(rt_dag.src_levels, src_before, "源电平必须自持：组件被改动后不得影响运行时")
	assert_eq(res_b.net_levels, res_a.net_levels,
			"纯逻辑结果被实体状态污染了（状态没有自持 / 存在回读组件）")

	# 4) 事件契约：只在有变化的拍发 outputs_changed
	var rt_ev := SWLogicRuntime.new()
	rt_ev.setup(prog, true)
	var emitted := [0]
	rt_ev.outputs_changed.connect(func(_r): emitted[0] = emitted[0] + 1)
	var changed := 0
	for t in 4:
		if rt_ev.src_count() > 0:
			rt_ev.set_source(0, t % 2)
		var r: SWSimResult = rt_ev.tick()
		if r.any_change:
			changed += 1
	assert_eq(emitted[0], changed, "outputs_changed 必须只在 any_change 的拍触发")

	# 5) 实体适配：结果镜像回 net 后必须与结果一致
	ctrl.apply_pure_result(circuit, res_a)
	var bad := 0
	for i in prog.net_list.size():
		if i >= res_a.net_levels.size():
			break
		var net := prog.net_list[i] as SWNet
		if net == null:
			continue
		var got: int = 1 if net.curSignal == SwDefine.CircuitSignal.HIGH else 0
		if got != res_a.net_levels[i]:
			bad += 1
	assert_eq(bad, 0, "apply_pure_result 之后有 %d 根 net 的 curSignal 与结果不一致" % bad)


# 把实体侧状态改到与运行时不符（用例只关心「纯逻辑一侧是否被影响」）
func _mutate_entity_state(prog: SWGateProgram) -> void:
	for i in prog.reg_comps.size():
		var reg := prog.reg_comps[i] as SWBuildCompoentCircuitRegister
		if reg == null:
			continue
		var next_q: SwDefine.CircuitSignal = SwDefine.CircuitSignal.HIGH
		if reg.qState == SwDefine.CircuitSignal.HIGH:
			next_q = SwDefine.CircuitSignal.LOW
		reg.qState = next_q
		return
	for i in prog.input_comps.size():
		var comp = prog.input_comps[i]
		if comp == null or comp.buildRef == null:
			continue
		var btn := comp.buildRef as SWBuildButton
		if btn != null:
			btn.pressed = not btn.pressed
			return
