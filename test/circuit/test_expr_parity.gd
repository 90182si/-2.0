extends GutTest
# SPEC-05 对拍：唯一表达式 DAG 求值 vs 原 gate 表逐层求值，逐拍逐 slot 必须完全一致。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_expr_parity.gd -gselect=test_expr_parity -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVES := ["加法器3", "16x计数器", "计数器2", "64x寄存器", "测试寄存器"]
const LOG_PATH := "j:/godot/无限地图/_expr.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_expr_parity() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	for save_name in SAVES:
		var data: Dictionary = await harness.load_save(save_name)
		if data.is_empty():
			_w("%s: LOAD FAILED" % save_name); continue
		var ctrl = harness.build_layer.layer_system.circuit_control
		var guard := 0
		while guard < 3000 and ctrl._cpu_backends.is_empty():
			guard += 1
			await get_tree().process_frame
		var tot_gates := 0
		var tot_expr := 0
		var tot_merged := 0
		var diff := 0
		var circuits := 0
		var bad_circuits := 0
		for cid in ctrl._cpu_backends:
			var prog: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
			circuits += 1
			tot_gates += prog.gate_count
			var ep: SWExprProgram = SWExprBuilder.new().build(prog, [])
			tot_expr += ep.expr_count
			tot_merged += ep.merged_from
			# 每个电路独立跑：自己一套引擎与状态，互不干扰
			var legacy := SWSignalEvalCPU.new()
			legacy.setup(prog)
			var vals := PackedInt32Array()
			vals.resize(ep.value_space())
			vals.fill(0)
			var n_in: int = prog.input_slots.size()
			var circ_diff := 0
			for tick in 12:
				var src_vals := PackedInt32Array()
				for i in n_in:
					src_vals.append((tick * 7 + i * 3 + tick / 2) % 2)
				legacy.clear_changed()
				legacy.write_sources(src_vals)
				legacy.evaluate()
				var rb: PackedInt32Array = legacy.readback()
				# 新引擎：源写入 → tick（组合 → 锁存 → Q 变了就同拍再传播）
				for i in n_in:
					vals[prog.input_slots[i]] = src_vals[i]
				vals = ep.tick(vals)
				for net in prog.net_to_slot:
					var s: int = prog.net_to_slot[net]
					if rb[s] != vals[s]:
						circ_diff += 1
			if circ_diff > 0:
				bad_circuits += 1
			diff += circ_diff
		_w("%s: circuits=%d(差异%d) gates=%d 唯一表达式=%d 合并=%d 差异=%d" % [
			save_name, circuits, bad_circuits, tot_gates, tot_expr, tot_merged, diff])
		assert_eq(diff, 0, "%s: 表达式 DAG 与原 gate 表求值不一致（%d 处，%d 个电路）" % [save_name, diff, bad_circuits])
	_dump()
	pass_test("expr parity done")

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines:
		f.store_line(l)
	f.close()
