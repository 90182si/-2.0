extends GutTest
# 16x计数器 真存档每拍成本基准：repro「修完仍 10 帧」。
# 用游戏同源入口（tick → buildSignalsChanged(clocks) → refresh_signal_chunks）跑 N 拍，
# 分解计时：求值 / 回填显示 / 信号纹理 / 渲染队列 flush / 整拍，输出 _perf_16x.txt。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "16x计数器"
const N := 120

const LOG_PATH := "j:/godot/无限地图/_perf_16x.txt"
var _lines: Array[String] = []

func _w(msg: String) -> void:
	_lines.append(msg)

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()

func test_bench_16x() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED")
		_dump()
		return
	var sys = harness.build_layer.layer_system
	var dm = harness.build_layer.sw_draw_manager
	var ctrl = sys.circuit_control
	#等分帧重建（stage 0..8）收尾
	var guard := 0
	while guard < 600 and not ctrl._neighborsCache.is_empty():
		guard += 1
		await get_tree().process_frame
	await harness.force_load_all_chunks()
	harness.flush_draw_queue()
	_w("staged_wait_frames=%d chunks_loaded=%d clocks=%d" % [
		guard, harness.force_load_all_chunks(), sys.clockBuildArr.size()])
	var backends: Dictionary = ctrl._cpu_backends
	if backends.is_empty():
		backends = ctrl._gpu_backends
	var tot_nets := 0
	var tot_gates := 0
	var tot_regs := 0
	var tot_leds := 0
	for circuit in backends:
		var prog = backends[circuit]["prog"]
		tot_nets += prog.net_to_slot.size()
		tot_gates += prog.gate_count
		tot_regs += prog.reg_slots.size()
		tot_leds += prog.led_comps.size()
	_w("circuits=%d nets=%d gates=%d regs=%d leds=%d" % [
		backends.size(), tot_nets, tot_gates, tot_regs, tot_leds])
	var clocks: Array[SWBuildItemDefine] = []
	clocks.assign(sys.clockBuildArr.keys())
	if clocks.is_empty():
		_w("NO CLOCKS")
		_dump()
		return
	var t_eval := []
	var t_refresh := []
	var t_flush := []
	var t_total := []
	var notify_max := 0
	var dbg_q_max := 0
	for i in N:
		for c in clocks:
			c.onPressed(true)
		var t0 := Time.get_ticks_usec()
		var changed: Array[SWBuildItemDefine] = ctrl.buildSignalsChanged(clocks)
		var t1 := Time.get_ticks_usec()
		sys.refresh_signal_chunks(changed)
		var t2 := Time.get_ticks_usec()
		dm._flush_patches(100000000)
		var t3 := Time.get_ticks_usec()
		t_eval.append(float(t1 - t0) / 1000.0)
		t_refresh.append(float(t2 - t1) / 1000.0)
		t_flush.append(float(t3 - t2) / 1000.0)
		t_total.append(float(t3 - t0) / 1000.0)
		notify_max = maxi(notify_max, changed.size())
		dbg_q_max = maxi(dbg_q_max, SwCommon.dbgQueue)
	_w("eval    med=%s avg=%s p90=%s max=%s" % [
		str(_med(t_eval)), str(_avg(t_eval)), str(_p(t_eval, 0.9)), str(_max(t_eval))])
	_w("refresh med=%s avg=%s max=%s" % [
		str(_med(t_refresh)), str(_avg(t_refresh)), str(_max(t_refresh))])
	_w("flush   med=%s avg=%s max=%s" % [
		str(_med(t_flush)), str(_avg(t_flush)), str(_max(t_flush))])
	_w("total   med=%s avg=%s p90=%s max=%s" % [
		str(_med(t_total)), str(_avg(t_total)), str(_p(t_total, 0.9)), str(_max(t_total))])
	_w("notify_max=%d dbgQueue_max=%d" % [notify_max, dbg_q_max])
	_w("engine FPS=%s" % str(Engine.get_frames_per_second()))
	_dump()
	pass_test("bench done")

static func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return roundf(s / a.size() * 1000.0) / 1000.0

static func _med(a: Array) -> float:
	return _p(a, 0.5)

static func _max(a: Array) -> float:
	return _p(a, 1.0)

static func _p(a: Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	var idx: int = mini(int(s.size() * q), s.size() - 1)
	return roundf(float(s[idx]) * 1000.0) / 1000.0
