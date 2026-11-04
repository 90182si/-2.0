extends GutTest
# 同进程交替 A/B：DAG vs gate表，消除整机负载漂移。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_dag_ab.gd -gselect=test_dag_ab -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "64x寄存器"
const ROUNDS := 5
const N := 30
const LOG_PATH := "j:/godot/无限地图/_dagab.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_dag_ab() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED"); _dump(); return
	var sys = harness.build_layer.layer_system
	var ctrl = sys.circuit_control
	var guard := 0
	while guard < 3000:
		guard += 1
		await get_tree().process_frame
		if ctrl._neighborsCache.is_empty() and not ctrl._cpu_backends.is_empty():
			break
	# 只测纯求值（不含回填）：直接调引擎
	var dag_engines: Array = []
	var gate_engines: Array = []
	var dag_vals: Array = []
	var gate_progs: Array = []
	var inputs: Array = []
	for cid in ctrl._cpu_backends:
		var cb: Dictionary = ctrl._cpu_backends[cid]
		var prog: SWGateProgram = cb["prog"]
		if cb["expr"] != null:
			dag_engines.append(cb["expr"])
			dag_vals.append(cb["expr_vals"])
		else:
			var ep: SWExprProgram = SWExprBuilder.new().build(prog, [])
			dag_engines.append(ep)
			var v := PackedInt32Array(); v.resize(ep.value_space()); v.fill(0)
			dag_vals.append(v)
		var ge := SWSignalEvalCPU.new(); ge.setup(prog)
		gate_engines.append(ge)
		inputs.append(prog.input_slots)
	var expr_total := 0
	var gate_total := 0
	for ep in dag_engines: expr_total += ep.expr_count
	for prog_i in ctrl._cpu_backends: gate_total += ctrl._cpu_backends[prog_i]["prog"].gate_count
	_w("表达式合计=%d  gate 合计=%d" % [expr_total, gate_total])

	var dag_times: Array = []
	var gate_times: Array = []
	for r in ROUNDS:
		# 交替顺序，抵消顺序效应
		if r % 2 == 0:
			dag_times.append(_run_dag(dag_engines, dag_vals, inputs))
			gate_times.append(_run_gate(gate_engines, inputs))
		else:
			gate_times.append(_run_gate(gate_engines, inputs))
			dag_times.append(_run_dag(dag_engines, dag_vals, inputs))
	for i in ROUNDS:
		_w("round%d: DAG=%.3f ms  gate=%.3f ms  比值=%.2f" % [
			i, dag_times[i], gate_times[i], dag_times[i] / maxf(gate_times[i], 0.001)])
	_w("中位: DAG=%.3f  gate=%.3f" % [_med(dag_times), _med(gate_times)])
	_dump()
	pass_test("ab done")

func _run_dag(engines: Array, valss: Array, inputs: Array) -> float:
	var t0 := Time.get_ticks_usec()
	for tick in N:
		for i in engines.size():
			var ep: SWExprProgram = engines[i]
			var ev: PackedInt32Array = valss[i]
			var ins: PackedInt32Array = inputs[i]
			for k in ins.size():
				ev[ins[k]] = (tick + k) % 2
			ep.tick(ev)
	return float(Time.get_ticks_usec() - t0) / 1000.0 / N

func _run_gate(engines: Array, inputs: Array) -> float:
	var t0 := Time.get_ticks_usec()
	for tick in N:
		for i in engines.size():
			var ge: SWSignalEvalCPU = engines[i]
			var ins: PackedInt32Array = inputs[i]
			var sv := PackedInt32Array()
			for k in ins.size():
				sv.append((tick + k) % 2)
			ge.clear_changed(); ge.write_sources(sv); ge.evaluate(); ge.readback()
	return float(Time.get_ticks_usec() - t0) / 1000.0 / N

static func _med(a: Array) -> float:
	var c: Array = a.duplicate(); c.sort()
	return c[c.size() / 2] if not c.is_empty() else 0.0

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines: f.store_line(l)
	f.close()
