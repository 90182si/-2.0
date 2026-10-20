extends GutTest
# 端到端回归：不手工注入事件，让游戏自己的 _process 时钟循环驱动计数器。
# 计数器冻结那次修复只有这条路能撞上——IR 三条求值路径（GDScript 变更定向 / 原生变更定向 /
# 原生整段重跑）和旧树路径都要真的在数。
# 只断言「状态至少变过两次」：拍数取决于每帧耗时，采样序列本身不可比对，
# 逐拍语义的一致性由 ir_parity_test.gd 的对拍负责。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_COUNTER := "2x计数器"
const SAMPLES := 12
const FRAMES_PER_SAMPLE := 10

func test_runtime_tick_gdscript_change_directed() -> void:
	await _run(true, true, false)

func test_runtime_tick_native_change_directed() -> void:
	await _run(true, true, true)

func test_runtime_tick_native_full_segment() -> void:
	await _run(true, false, true)

func test_runtime_tick_tree_path() -> void:
	await _run(false, false, false)

func _run(use_ir: bool, change_directed: bool, native: bool) -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	control.useIR = use_ir
	control.useChangeDirected = change_directed
	control.useNativeEval = native
	var data: Dictionary = await harness.load_save(SAVE_COUNTER)
	if data.is_empty():
		pending("存档不存在，跳过: " + SAVE_COUNTER)
		await _dispose(harness)
		return
	# 存档里开关全灭：加数为 0 时 Q+0=Q 本就保持不变，先拨亮才复刻用户实测的跳数场景
	assert_gt(_light_switches(harness), 0, "存档里没有可拨的开关")
	var seq: Array = []
	for s in range(SAMPLES):
		for f in range(FRAMES_PER_SAMPLE):
			await get_tree().process_frame
		seq.append(_snapshot(harness))
	var distinct := {}
	for v in seq:
		distinct[v] = true
	assert_gt(distinct.size(), 1, "%s 模式计数器从未变化（最后位串 %s）" % [_tag(use_ir, change_directed, native), seq[seq.size() - 1]])
	await _dispose(harness)

func _tag(use_ir: bool, change_directed: bool, native: bool) -> String:
	if not use_ir:
		return "旧树路径"
	return ("GDScript" if not native else "原生") + ("·变更定向" if change_directed else "·整段")

## 把存档里全部开关拨亮：否则加数为 0，计数器保持 0 是正确行为而不是 bug
func _light_switches(harness) -> int:
	var sw_n := 0
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			if harness.set_switch(b.buildAxisPos, true):
				sw_n += 1
	return sw_n

func _snapshot(harness) -> String:
	var leds: Array = []
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.LED:
			leds.append(b)
	leds.sort_custom(func(a, c): return a.buildAxisPos.y * 100000 + a.buildAxisPos.x < c.buildAxisPos.y * 100000 + c.buildAxisPos.x)
	var ret := ""
	for b in leds:
		ret += "1" if b.getDisplaySignal() == SwDefine.CircuitSignal.HIGH else "0"
	return ret

func _dispose(harness) -> void:
	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()
