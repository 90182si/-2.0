extends GutTest
# 默认配置（只回填三类元件）下的 64x 存档每拍耗时。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_bench_default.gd -gselect=test_bench_default -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "64x寄存器"
const N := 40
const LOG_PATH := "j:/godot/无限地图/_perf_default.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_bench_default() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED"); _dump(); return
	var sys = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var ctrl = sys.circuit_control
	var guard := 0
	while guard < 3000:
		guard += 1
		await get_tree().process_frame
		if ctrl._neighborsCache.is_empty() and not ctrl._cpu_backends.is_empty():
			break
	var clocks: Array = sys.clockBuildArr.keys()
	_w("默认开关: backfill_net_signal=%s backfill_gate_display=%s" % [
		str(ctrl.backfill_net_signal), str(ctrl.backfill_gate_display)])
	_w("enable_expr_dag=%s enable_native=%s" % [
		str(ctrl.enable_expr_dag), str(SWExprBuilder.new().enable_native)])
	var tg := 0; var tn := 0; var te := 0
	for cid in ctrl._cpu_backends:
		var prog: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
		tg += prog.gate_count
		tn += prog.net_to_slot.size()
		if ctrl._cpu_backends[cid]["expr"] != null:
			te += ctrl._cpu_backends[cid]["expr"].expr_count
	_w("circuits=%d nets=%d gates=%d 唯一表达式=%d" % [
		ctrl._cpu_backends.size(), tn, tg, te])
	# 预热
	for i in 5:
		for c in clocks: c.onPressed(true)
		ctrl.buildSignalsChanged(clocks)
	var times: Array = []
	for i in N:
		for c in clocks: c.onPressed(true)
		var t0 := Time.get_ticks_usec()
		var changed = ctrl.buildSignalsChanged(clocks)
		sys.refresh_signal_chunks(changed)
		dm._flush_patches(100000000)
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	_w("每拍 total: med=%.2f p90=%.2f max=%.2f ms" % [
		times[times.size() / 2], times[int(times.size() * 0.9)], times[times.size() - 1]])
	_dump()
	pass_test("default bench done")

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines: f.store_line(l)
	f.close()
