extends GutTest
# 「简化表达式求值」开关的端到端契约（性能面板的「电线/非门跟随电平」驱动）：
#   1. 简化版 prog 与原始 prog 的 slot 空间、gate 条数完全一致（回填表才能直接复用）；
#   2. 同一份输入下，两个后端算出的每个 net 电平逐位一致；
#   3. 开关切换会让 CPU 后端失效重建（两份程序的 gates 不同，不能共用）；
#   4. 求值用的哪一份由 use_simplified_eval 决定，回填永远读原始 prog 的扁平表。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_simplified_eval -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

func _boot() -> Variant:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save("加法器3")
	assert_false(data.is_empty(), "加法器3 存档要能加载")
	var ctrl = harness.build_layer.layer_system.circuit_control
	var guard := 0
	while guard < 3000 and ctrl._cpu_backends.is_empty():
		guard += 1
		await get_tree().process_frame
	assert_false(ctrl._cpu_backends.is_empty(), "CPU 后端要跑起来")
	return ctrl

func _run(prog: SWGateProgram, src_vals: PackedInt32Array, ticks: int) -> Array:
	var e := SWSignalEvalCPU.new()
	e.setup(prog)
	var out: Array = []
	for tick in ticks:
		var vals := PackedInt32Array()
		for i in prog.input_slots.size():
			vals.append((tick * 7 + i * 3 + tick / 2) % 2)
		e.clear_changed()
		e.write_sources(vals)
		e.evaluate()
		out.append(e.readback().duplicate())
	return out

# 1) 简化版与原始版的契约一致 + 求值逐位等价
func test_simplified_eval_matches_raw() -> void:
	var ctrl = await _boot()
	var compared := 0
	for cid in ctrl._cpu_backends:
		var raw: SWGateProgram = ctrl._compiled_prog(cid)
		var simple: SWGateProgram = ctrl._simplified_prog(cid)
		assert_eq(simple.slot_count, raw.slot_count, "slot 空间必须一致（回填表按 slot 下标读）")
		assert_eq(simple.gate_count, raw.gate_count, "gate 条数必须一致")
		for gi in raw.gate_count:
			var base: int = gi * SWGateProgram.STRIDE
			if simple.gates[base + 1] != raw.gates[base + 1]:
				assert_eq(simple.gates[base + 1], raw.gates[base + 1], "第 %d 条 gate 的 dst 不能变" % gi)
				break
		var a_list := _run(raw, PackedInt32Array(), 12)
		var b_list := _run(simple, PackedInt32Array(), 12)
		for t in a_list.size():
			var a: PackedInt32Array = a_list[t]
			var b: PackedInt32Array = b_list[t]
			for net in raw.net_to_slot:
				var s: int = raw.net_to_slot[net]
				assert_eq(b[s], a[s], "第 %d 拍 net slot %d 化简前后不一致" % [t, s])
		compared += 1
	assert_gt(compared, 0, "至少要比过一个电路")
	pass_test("done")

# 2) 开关切换：后端按 simple 标记惰性失效，下次取用时重建，来回切后仍然等价
func test_toggle_rebuilds_backends() -> void:
	var ctrl = await _boot()
	var cid = null
	for c in ctrl._cpu_backends:
		cid = c
		break
	assert_not_null(cid, "要有一个 CPU 后端")
	var before: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
	assert_false(ctrl._cpu_backends[cid]["simple"], "默认应当走未简化程序")

	ctrl.set_use_simplified_eval(true)
	assert_gt(ctrl._cpu_backends.size(), 0, "切开关不清空后端（惰性失效，不能用空窗口冻住静止电路）")
	var after: Dictionary = ctrl._ensure_cpu_backend(cid)
	assert_true(after["simple"], "标记要跟着开关走")
	assert_ne((after["prog"] as SWGateProgram).gates, before.gates, "简化版确实是另一份 gate 表")
	assert_true(ctrl._cpu_backends[cid]["simple"], "缓存里也要换成简化后端")

	ctrl.set_use_simplified_eval(false)
	var back: Dictionary = ctrl._ensure_cpu_backend(cid)
	assert_false(back["simple"], "切回来要重新用原始程序")
	assert_eq((back["prog"] as SWGateProgram).gates, before.gates, "切回来就是原来那份 gate 表")

# 3) 化简收益诊断字段
func test_simplify_stats_are_sane() -> void:
	var ctrl = await _boot()
	for cid in ctrl._cpu_backends:
		var st: Dictionary = ctrl.get_simplify_stats(cid)
		assert_gt(int(st["gates"]), 0, "要统计到 gate")
		assert_true(int(st["optimized"]) >= 0, "化简条数不能是负数")
		assert_gt(int(st["optimized"]), 0, "加法器单驱动 net 很多，至少有一批单输入线与能直通")
		assert_true(bool(st["same"]), "gate 条数必须保持不变")
