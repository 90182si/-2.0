extends GutTest
# SPEC-06 性能：原生（GDExtension）vs GDScript 求值，同进程交替 A/B。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_native_ab.gd -gselect=test_native_ab -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "64x寄存器"
const ROUNDS := 5
const N := 40
const LOG_PATH := "j:/godot/无限地图/_nativeab.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_native_ab() -> void:
	if not ClassDB.class_exists("SWExprEval"):
		_w("GDExtension 未加载，跳过")
		_dump()
		pass_test("跳过（扩展未加载）")
		return
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		_w("LOAD FAILED"); _dump(); return
	var ctrl = harness.build_layer.layer_system.circuit_control
	var guard := 0
	while guard < 3000:
		guard += 1
		await get_tree().process_frame
		if ctrl._neighborsCache.is_empty() and not ctrl._cpu_backends.is_empty():
			break
	# 每个电路两组 DAG：原生 / GDScript
	var e_nat: Array = []
	var e_gs: Array = []
	var v_nat: Array = []
	var v_gs: Array = []
	var inputs: Array = []
	var tot_expr := 0
	var tot_seg := 0
	for cid in ctrl._cpu_backends:
		var prog: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
		var bn := SWExprBuilder.new(); bn.enable_native = true
		var en: SWExprProgram = bn.build(prog, [])
		var bg := SWExprBuilder.new(); bg.enable_native = false
		var eg: SWExprProgram = bg.build(prog, [])
		e_nat.append(en); e_gs.append(eg); inputs.append(prog.input_slots)
		tot_expr += en.expr_count
		tot_seg += en.op_seg_kind.size()
		var a := PackedInt32Array(); a.resize(en.value_space()); a.fill(0)
		var b := PackedInt32Array(); b.resize(eg.value_space()); b.fill(0)
		v_nat.append(a); v_gs.append(b)
	_w("表达式合计=%d 段合计=%d 电路=%d" % [tot_expr, tot_seg, e_nat.size()])
	var nat_t: Array = []
	var gs_t: Array = []
	for r in ROUNDS:
		if r % 2 == 0:
			nat_t.append(_run(e_nat, v_nat, inputs, true))
			gs_t.append(_run(e_gs, v_gs, inputs, false))
		else:
			gs_t.append(_run(e_gs, v_gs, inputs, false))
			nat_t.append(_run(e_nat, v_nat, inputs, true))
	for i in ROUNDS:
		_w("round%d: 原生=%.3f ms  GDScript=%.3f ms  加速=%.1fx" % [
			i, nat_t[i], gs_t[i], gs_t[i] / maxf(nat_t[i], 0.0001)])
	_w("中位: 原生=%.3f  GDScript=%.3f  加速=%.1fx" % [
		_med(nat_t), _med(gs_t), _med(gs_t) / maxf(_med(nat_t), 0.0001)])
	_dump()
	pass_test("native ab done")

func _run(engines: Array, valss: Array, inputs: Array, is_native: bool) -> float:
	var t0 := Time.get_ticks_usec()
	for tick in N:
		for i in engines.size():
			var ep: SWExprProgram = engines[i]
			var ev: PackedInt32Array = valss[i]
			var ins: PackedInt32Array = inputs[i]
			for k in ins.size():
				ev[ins[k]] = (tick + k) % 2
			valss[i] = ep.tick(ev)
	return float(Time.get_ticks_usec() - t0) / 1000.0 / N

static func _med(a: Array) -> float:
	var c: Array = a.duplicate(); c.sort()
	return c[c.size() / 2] if not c.is_empty() else 0.0

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines: f.store_line(l)
	f.close()
