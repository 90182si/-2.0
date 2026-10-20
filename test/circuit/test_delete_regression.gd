extends GutTest
# 删除建筑的回归用例：走 GUI 真实入口 _do_delete_selected()（选中→Delete），
# 删完再空转若干帧，让 _process 的时钟循环撞上「刚被删的电路」。
# 修前两件事：删除漏调 updateBuildCircuit/delClockBuild（旧时钟继续逐拍驱动已失效电路 → 闪退），
# 以及重编译后原生侧 CSR 残留上一轮计数（下标越界 → FATAL）。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_COUNTER := "2x计数器"

func test_delete_clock_full_segment() -> void:
	await _run(true, false)

func test_delete_clock_change_directed() -> void:
	await _run(true, true)

func test_delete_register_full_segment() -> void:
	await _run(false, false)

func test_delete_register_change_directed() -> void:
	await _run(false, true)

func _run(delete_clock: bool, change_directed: bool) -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	control.useIR = true
	control.useChangeDirected = change_directed
	control.useNativeEval = true
	var data: Dictionary = await harness.load_save(SAVE_COUNTER)
	if data.is_empty():
		pending("存档不存在，跳过: " + SAVE_COUNTER)
		await _dispose(harness)
		return
	_turn_on_switches(harness)
	var victim := _pick(harness, delete_clock)
	if victim == null:
		fail_test("没找到要删的建筑")
		await _dispose(harness)
		return
	var label := "时钟" if delete_clock else "寄存器"
	var victim_id: int = victim.id
	var clock_n_before: int = harness.build_layer.clockBuildArr.size()
	harness.build_layer.selectedBuilds[victim] = true
	harness.build_layer._do_delete_selected()
	assert_false(_has_build(harness, victim_id), "%s 删除后仍能按 id 查到" % label)
	if delete_clock:
		assert_eq(harness.build_layer.clockBuildArr.size(), clock_n_before - 1,
			"删除的时钟没从 clockBuildArr 注销，仍会逐拍驱动旧电路")
	var seq: Array = []
	for f in range(180):
		await get_tree().process_frame
		if f % 30 == 29:
			seq.append(_snap(harness))
	var distinct := {}
	for v in seq:
		distinct[v] = true
	assert_gt(distinct.size(), 1, "删除%s后存活的那路计数器不再走动" % label)
	await _dispose(harness)

func _has_build(harness, build_id: int) -> bool:
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.id == build_id:
			return true
	return false

func _pick(harness, want_clock: bool) -> SWBuildItemDefine:
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if want_clock and b is SWBuildClockSiggen:
			return b
		if not want_clock and b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.ONE_BIT_REGISTER:
			return b
	return null

func _turn_on_switches(harness) -> void:
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			harness.set_switch(b.buildAxisPos, true)

func _snap(harness) -> String:
	var ret := ""
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.LED:
			ret += "1" if b.getDisplaySignal() == SwDefine.CircuitSignal.HIGH else "0"
	return ret

func _dispose(harness) -> void:
	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()
