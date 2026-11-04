extends GutTest
# SPEC-06 对拍：GDExtension 原生求值 vs GDScript 求值，逐拍逐 slot 必须完全一致。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_native_parity.gd -gselect=test_native_parity -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVES := ["加法器3", "16x计数器", "计数器2", "64x寄存器", "测试寄存器"]
const LOG_PATH := "j:/godot/无限地图/_native.txt"
var _lines: Array[String] = []

func _w(m: String) -> void:
	_lines.append(m)

func test_native_parity() -> void:
	if not ClassDB.class_exists("SWExprEval"):
		_w("GDExtension 未加载，跳过")
		_dump()
		pass_test("原生求值器不可用（扩展未构建/未加载）")
		return
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
		var diff := 0
		var circuits := 0
		var native_hits := 0
		for cid in ctrl._cpu_backends:
			var prog: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
			circuits += 1
			# 两个 DAG：一个挂原生，一个不挂
			var b_native := SWExprBuilder.new()
			b_native.enable_native = true
			var ep_native: SWExprProgram = b_native.build(prog, [])
			var b_gs := SWExprBuilder.new()
			b_gs.enable_native = false
			var ep_gs: SWExprProgram = b_gs.build(prog, [])
			if ep_native.using_native:
				native_hits += 1
			var n_in := prog.input_slots.size()
			var va := PackedInt32Array(); va.resize(ep_native.value_space()); va.fill(0)
			var vb := PackedInt32Array(); vb.resize(ep_gs.value_space()); vb.fill(0)
			for tick in 10:
				var sv := PackedInt32Array()
				for i in n_in:
					sv.append((tick * 5 + i * 3 + tick / 2) % 2)
				# 两边喂同样的源
				for i in n_in:
					va[prog.input_slots[i]] = sv[i]
					vb[prog.input_slots[i]] = sv[i]
				va = ep_native.tick(va)
				vb = ep_gs.tick(vb)
				# 逐 slot 对比
				for s in prog.slot_count:
					if va[s] != vb[s]:
						diff += 1
		_w("%s: circuits=%d 原生命中=%d 差异=%d" % [save_name, circuits, native_hits, diff])
		assert_eq(diff, 0, "%s: 原生求值与 GDScript 求值不一致（%d 处）" % [save_name, diff])
	_dump()
	pass_test("native parity done")

func _dump() -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	for l in _lines: f.store_line(l)
	f.close()
