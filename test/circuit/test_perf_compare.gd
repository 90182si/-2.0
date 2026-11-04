extends GutTest
# T1.10 性能对比探针：GPU 全量求值 vs CPU 增量求值（真机 D3D12）
# 同一电路（存档"加法器3"，246 gate），与游戏一致入口 buildSignalChanged(btn)。
# 场景A：每拍翻转一个开关（事件密集）
# 场景B：每拍不翻转（静态拍，CPU 增量 O(0) vs GPU 全量 O(N)）
# 输出写 _perf_compare.txt

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"
const SWITCH_POS: Array = [
	Vector2i(5760, 3456), Vector2i(4480, 3456), Vector2i(3200, 3456),
	Vector2i(1920, 3456), Vector2i(5888, 3072),
]
const N_ITERS := 80

var harness = null
var _out: FileAccess

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	_out = FileAccess.open("j:/godot/无限地图/_perf_compare.txt", FileAccess.WRITE)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null
	if _out != null:
		_out.close()
		_out = null

func _w(msg: String) -> void:
	if _out != null:
		_out.store_line(msg)

func _sw_buttons() -> Array:
	var arr: Array = []
	for pos in SWITCH_POS:
		var build = harness.get_build(pos)
		var btn := build as SWBuildButton
		if btn != null:
			arr.append(btn)
	return arr

func _measure(ctrl, btns: Array, iters: int, toggle: bool) -> float:
	# 预热（GPU 首次 ensure backend / 编译不进计时）
	ctrl.buildSignalChanged(btns[0])
	var t0 := Time.get_ticks_usec()
	for i in iters:
		var b = btns[i % btns.size()]
		if toggle:
			b.pressed = not b.pressed
		ctrl.buildSignalChanged(b)
	var t1 := Time.get_ticks_usec()
	return float(t1 - t0) / float(iters) / 1000.0

func test_perf_compare() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		fail_test("存档加载失败")
		return
	var sys = harness.build_layer.layer_system
	var ctrl = sys.circuit_control
	var btns := _sw_buttons()
	_w("[PERF] buttons=%d gate=246" % btns.size())
	# 归一：全部复位
	for b in btns:
		b.pressed = false
	# GPU 路径（先测，热 backend）
	ctrl.gpu_backend_enabled = true
	var gpu_change := _measure(ctrl, btns, N_ITERS, true)
	var gpu_static := _measure(ctrl, btns, N_ITERS, false)
	# CPU 增量路径
	ctrl.gpu_backend_enabled = false
	var cpu_change := _measure(ctrl, btns, N_ITERS, true)
	var cpu_static := _measure(ctrl, btns, N_ITERS, false)
	_w("[PERF] 事件拍(翻转开关) GPU=%.3fms CPU=%.3fms ratio=%.2fx" % [gpu_change, cpu_change, cpu_change / gpu_change])
	_w("[PERF] 静态拍(无变化)   GPU=%.3fms CPU=%.3fms ratio=%.2fx" % [gpu_static, cpu_static, cpu_static / gpu_static])
	# GPU 三段分解：write_sources / evaluate(submit+sync) / readback 各自平均耗时
	ctrl.gpu_backend_enabled = true
	for circuit in ctrl._gpu_backends:
		var bk: Dictionary = ctrl._gpu_backends[circuit]
		var eng = bk["engine"]
		if eng.is_broken():
			continue
		var pg = bk["prog"]
		var vals := PackedInt32Array()
		for i in pg.input_slots.size():
			vals.append(i % 2)
		eng.write_sources(vals)
		eng.evaluate()
		eng.readback()
		var t0 := Time.get_ticks_usec()
		for i in N_ITERS:
			eng.write_sources(vals)
		var t1 := Time.get_ticks_usec()
		var ws := float(t1 - t0) / N_ITERS / 1000.0
		t0 = Time.get_ticks_usec()
		for i in N_ITERS:
			eng.evaluate()
		t1 = Time.get_ticks_usec()
		var ev := float(t1 - t0) / N_ITERS / 1000.0
		t0 = Time.get_ticks_usec()
		for i in N_ITERS:
			eng.readback()
		t1 = Time.get_ticks_usec()
		var rb := float(t1 - t0) / N_ITERS / 1000.0
		_w("[PERF] GPU 分解 ws=%.3fms eval(submit+sync)=%.3fms rb=%.3fms" % [ws, ev, rb])
	pass_test("性能对比输出完成")
