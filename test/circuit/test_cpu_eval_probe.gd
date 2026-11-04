extends GutTest
# T1.10 方案 A 验证：CPU 数据驱动求值（SWSignalEvalCPU）语义与 GPU 路径一致。
# 输入/期望与 test_circuit_led（GPU 路径 12/12 全过）完全相同，这里强制 gpu_backend_enabled=false
# 走 CPU 数据驱动一轮，断言灯泡状态符合同一期望（4 LOW + 1 HIGH）。
# 输出 _cpu_probe.txt

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"
const SWITCHES: Array = [
	Vector2i(5760, 3456), Vector2i(4480, 3456), Vector2i(3200, 3456),
	Vector2i(1920, 3456), Vector2i(5888, 3072),
]
const LEDS: Array = [
	Vector2i(6016, 384), Vector2i(4736, 384), Vector2i(3456, 384),
	Vector2i(2176, 384), Vector2i(896, 384),
]
const LED_EXPECT: Array = [
	SwDefine.CircuitSignal.LOW, SwDefine.CircuitSignal.LOW, SwDefine.CircuitSignal.LOW,
	SwDefine.CircuitSignal.LOW, SwDefine.CircuitSignal.HIGH,
]

func test_cpu_fastpath_matches_gpu() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	assert_false(data.is_empty(), "存档加载失败")
	var ctrl = harness.build_layer.layer_system.circuit_control
	ctrl.gpu_backend_enabled = false
	for pos in SWITCHES:
		harness.set_switch(pos, true)
	await wait_process_frames(1)
	var states: Array = []
	for pos in LEDS:
		states.append(harness.get_signal_state(pos))
	var f := FileAccess.open("j:/godot/无限地图/_cpu_probe.txt", FileAccess.WRITE)
	for i in LEDS.size():
		var match_exp: bool = states[i] == LED_EXPECT[i]
		f.store_line("led[%s] cpu=%d expect=%d match=%s" % [
			str(LEDS[i]), states[i], LED_EXPECT[i], str(match_exp)])
	f.close()
	for i in LEDS.size():
		assert_eq(states[i], LED_EXPECT[i], "CPU 数据驱动 led[%s] 期望 %d 实际 %d" % [str(LEDS[i]), LED_EXPECT[i], states[i]])
	pass_test("CPU 数据驱动与 GPU 期望一致")
