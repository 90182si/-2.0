extends GutTest
# 网表编译对拍（step 1 的验收）：
#   「builds → SWNetlist → compile_netlist」与老的「直接读组件 pinNetMap」两条路径，
#   必须产出**逐字段完全相同**的 SWGateProgram（slot 编号是对外契约：
#   net slot / comp slot / 折叠链中间 slot / CSE alias 都不能差一个数）。
#
# 跑法（单文件，不要跑全量）：
#   godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit \
#         -gprefix=test_netlist_compile -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVES := ["ledbug2", "加法器3", "16x计数器", "测试寄存器", "64x寄存器"]

var harness = null


func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)


func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null


func test_netlist_compile_matches_legacy() -> void:
	await harness.boot_game()
	var checked := 0
	for save_name in SAVES:
		var data: Dictionary = await harness.load_save(save_name)
		if data.is_empty():
			push_error("存档加载失败: " + save_name)
			continue
		var ctrl = harness.build_layer.layer_system.circuit_control
		# 等懒建后端把电路表填出来（与 test_expr_parity 同口径）
		var guard := 0
		while guard < 3000 and ctrl._cpu_backends.is_empty():
			guard += 1
			await get_tree().process_frame
		# ① 全图一次合编（与 test_cpu_flat 同口径，net 数最多，最容易暴露顺序差）
		var all_builds: Array = harness.build_layer.layer_system.build_manager.getAllBuilds()
		if not all_builds.is_empty():
			_assert_parity("全图/" + save_name, all_builds)
			checked += 1
		# ② 逐电路各对一次：电路 buildArr 才是产品真正喂给编译器的输入
		for c in ctrl._cpu_backends.keys():
			if c == null or c.buildArr == null or c.buildArr.is_empty():
				continue
			_assert_parity("%s/circuit#%s" % [save_name, str(c.circuitID)], c.buildArr)
			checked += 1
	assert_true(checked > 0, "没有可对拍的电路（存档缺失？）")
	pass_test("已对拍 %d 组" % checked)


# 注意：不能叫 _compare —— GutTest 基类里已经有一个 _compare 成员（Comparator）
func _assert_parity(tag: String, builds: Array) -> void:
	# 老路径（默认）
	var legacy: SWGateProgram = SWGateCompiler.new().compile(builds)
	# 纯数据路径：导出网表 → 只读网表编译 → 再回接实体表
	var ex := SWNetlistExport.new()
	var nl: SWNetlist = ex.export_netlist(builds)
	assert_true(nl.dev_count() > 0, tag + " 网表为空")
	# 不直接断言 net_count > 0：读档换世界时后端表里可能残留上一份世界的退化电路
	# （元件在、net 已注销），那种情形老路径也是 0 根 net。要断言的是「两边口径一致」。
	assert_eq(nl.net_count(), legacy.net_count, tag + " 网表 net 数与老路径不一致（拓扑导出漏 net）")
	var pure: SWGateProgram = SWGateCompiler.new().compile_netlist(nl)
	# 未回接前，prog 里不应有任何对象表（compile_netlist 只吃整数）
	assert_true(pure.all_comps.is_empty(), tag + " compile_netlist 不应绑定组件")
	assert_true(pure.net_list.is_empty(), tag + " compile_netlist 不应绑定 net")
	ex.bind_program(pure)
	_assert_same_prog(legacy, pure, tag)


# 逐字段比对：任何一项不等都给出「第几项、值多少」，比 assert_eq 整块数组好定位
func _assert_same_prog(a: SWGateProgram, b: SWGateProgram, tag: String) -> void:
	assert_eq(b.slot_count, a.slot_count, tag + " slot_count")
	assert_eq(b.net_count, a.net_count, tag + " net_count")
	assert_eq(b.comp_count, a.comp_count, tag + " comp_count")
	assert_eq(b.gate_count, a.gate_count, tag + " gate_count")
	assert_eq(b.raw_gate_count, a.raw_gate_count, tag + " raw_gate_count")
	assert_eq(b.level_count, a.level_count, tag + " level_count")
	assert_eq(b.loop_nets, a.loop_nets, tag + " loop_nets")
	assert_eq(b.cse_merged, a.cse_merged, tag + " cse_merged")
	_same_i32(a.gates, b.gates, tag + " gates")
	_same_i32(a.level_starts, b.level_starts, tag + " level_starts")
	_same_i32(a.level_counts, b.level_counts, tag + " level_counts")
	_same_i32(a.loop_slot_flags, b.loop_slot_flags, tag + " loop_slot_flags")
	_same_i32(a.net_slots, b.net_slots, tag + " net_slots")
	_same_i32(a.net_prev_bit, b.net_prev_bit, tag + " net_prev_bit")
	_same_i32(a.input_slots, b.input_slots, tag + " input_slots")
	_same_i32(a.reg_slots, b.reg_slots, tag + " reg_slots")
	_same_i32(a.reg_clk_slots, b.reg_clk_slots, tag + " reg_clk_slots")
	_same_i32(a.reg_d_slots, b.reg_d_slots, tag + " reg_d_slots")
	# LED：逐灯泡的输入集合 + 分组表
	_same_nested(a.led_src_slots, b.led_src_slots, tag + " led_src_slots")
	_same_i32(a.led_group_id, b.led_group_id, tag + " led_group_id")
	_same_i32(a.led_group_src_flat, b.led_group_src_flat, tag + " led_group_src_flat")
	_same_i32(a.led_group_src_offs, b.led_group_src_offs, tag + " led_group_src_offs")
	_same_i32(a.led_group_src_lens, b.led_group_src_lens, tag + " led_group_src_lens")
	_same_i32(a.led_group_members, b.led_group_members, tag + " led_group_members")
	_same_i32(a.led_group_mem_offs, b.led_group_mem_offs, tag + " led_group_mem_offs")
	_same_i32(a.led_group_mem_lens, b.led_group_mem_lens, tag + " led_group_mem_lens")
	_same_i32(a.led_group_prev, b.led_group_prev, tag + " led_group_prev")
	# 门显示表
	_same_i32(a.gate_out_slots, b.gate_out_slots, tag + " gate_out_slots")
	_same_i32(a.gate_prev_level, b.gate_prev_level, tag + " gate_prev_level")
	_same_i32(a.gate_display_invert, b.gate_display_invert, tag + " gate_display_invert")
	# 回接后的对象表（顺序也必须一致，回填按下标访问）
	assert_eq(b.net_list.size(), a.net_list.size(), tag + " net_list.size")
	assert_eq(b.all_comps.size(), a.all_comps.size(), tag + " all_comps.size")
	assert_eq(b.display_comps.size(), a.display_comps.size(), tag + " display_comps.size")
	assert_eq(b.fallback_display_comps.size(), a.fallback_display_comps.size(),
			tag + " fallback_display_comps.size")
	assert_eq(b.led_comps.size(), a.led_comps.size(), tag + " led_comps.size")
	assert_eq(b.led_refresh_comps.size(), a.led_refresh_comps.size(), tag + " led_refresh_comps.size")
	assert_eq(b.gate_refresh_comps.size(), a.gate_refresh_comps.size(), tag + " gate_refresh_comps.size")
	assert_eq(b.reg_comps.size(), a.reg_comps.size(), tag + " reg_comps.size")
	assert_eq(b.input_comps.size(), a.input_comps.size(), tag + " input_comps.size")
	for i in mini(a.net_list.size(), b.net_list.size()):
		assert_eq(b.net_list[i], a.net_list[i], "%s net_list[%d] 顺序不一致" % [tag, i])
	for i in mini(a.reg_comps.size(), b.reg_comps.size()):
		assert_eq(b.reg_comps[i], a.reg_comps[i], "%s reg_comps[%d] 顺序不一致" % [tag, i])
	for i in mini(a.input_comps.size(), b.input_comps.size()):
		assert_eq(b.input_comps[i], a.input_comps[i], "%s input_comps[%d] 顺序不一致" % [tag, i])
	# netId → slot 映射
	assert_eq(b.net_id_to_slot.size(), a.net_id_to_slot.size(), tag + " net_id_to_slot.size")
	for k in a.net_id_to_slot:
		assert_eq(b.net_id_to_slot.get(k, -999), a.net_id_to_slot[k],
				"%s net_id_to_slot[%s]" % [tag, str(k)])


func _same_i32(a, b, tag: String) -> void:
	var msg := ""
	if a.size() != b.size():
		msg = "长度 %d != %d" % [a.size(), b.size()]
	else:
		for i in a.size():
			if a[i] != b[i]:
				msg = "第 %d 项 %d != %d" % [i, a[i], b[i]]
				break
	assert_eq(msg, "", tag)


func _same_nested(a: Array, b: Array, tag: String) -> void:
	if a.size() != b.size():
		assert_eq(b.size(), a.size(), tag + ".size")
		return
	for i in a.size():
		_same_i32(a[i], b[i], "%s[%d]" % [tag, i])
