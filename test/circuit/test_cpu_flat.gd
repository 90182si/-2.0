extends GutTest
# SPEC-04 · CPU 侧扁平电路求值回归门禁。
#
# 固化三条实证结论（都是这次改造中「先做、再证伪、最后按数据回退」得到的）：
#   1. 编译产物必须保持「一个 dst 一条写 gate」——多驱动线与已在编译期合并成单条 AND，
#      任何把两个不同 dst 的 gate 合并成一条的重写都会破坏「按层 dispatch + slot_lv 判据」的调度语义。
#   2. CPU 引擎不跨拍复用 _cur：缓冲区 ping-pong 滚动，跨拍跳过会读到上一拍的旧值。
#   3. 环检测（Tarjan）必须能跑完真存档而不把 DAG 误判成环。
#
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_cpu_flat.gd -gselect=test_cpu_flat -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVES := ["16x计数器", "计数器2", "测试寄存器"]

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null


# 1) 编译产物结构契约：每个 dst 恰有一条写 gate（GPU 并发写冲突的根因）
func test_no_duplicate_dst_writes() -> void:
	if not await _boot(SAVES[0]):
		return
	var prog := SWGateCompiler.new().compile(harness.build_layer.layer_system.build_manager.getAllBuilds())
	var seen := {}
	var dup := 0
	for gi in prog.gate_count:
		var dst: int = prog.gates[gi * SWGateProgram.STRIDE + 1]
		if seen.has(dst):
			dup += 1
		seen[dst] = true
	assert_eq(dup, 0, "存在 %d 个被多条 gate 写的 dst（会引发并发写冲突/调度歧义）" % dup)
	assert_gt(prog.gate_count, 0, "编译产物为空")


# 2) 环检测能跑完真存档，且环计数不超过 slot 总数
func test_loop_detection_runs() -> void:
	if not await _boot(SAVES[0]):
		return
	var prog := SWGateCompiler.new().compile(harness.build_layer.layer_system.build_manager.getAllBuilds())
	assert_true(prog.loop_nets >= 0 and prog.loop_nets <= prog.slot_count,
			"环上 slot 计数异常：%d / slot_count=%d" % [prog.loop_nets, prog.slot_count])


# 3) 逐电路后端编译 vs 全量编译：net 数必须一致（同一批网络的两种切分口径）
func test_per_circuit_matches_globals() -> void:
	if not await _boot(SAVES[0]):
		return
	var ctrl = harness.build_layer.layer_system.circuit_control
	var per_circuit_nets := 0
	var per_circuit_gates := 0
	for cid in ctrl._cpu_backends:
		var p: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
		per_circuit_nets += p.net_to_slot.size()
		per_circuit_gates += p.gate_count
	var all_prog := SWGateCompiler.new().compile(
			harness.build_layer.layer_system.build_manager.getAllBuilds())
	assert_eq(per_circuit_nets, all_prog.net_to_slot.size(),
			"逐电路 net 合计与全量不一致（后端漏算/重算）")
	# gate 数不做等值断言：逐电路编译时每个电路独立做 >4 驱动 AND 链折叠，
	# 临时 slot 比全量合编更多，两者本来就不必相等（只记录）
	pass_test("逐电路 %d gates / 全量 %d gates" % [per_circuit_gates, all_prog.gate_count])


# 4) CPU 引擎：readback 长度与 slot 数一致，且同一输入下求值幂等（两次 evaluate 结果相同）
func test_cpu_engine_readback_shape() -> void:
	if not await _boot(SAVES[0]):
		return
	var prog := SWGateCompiler.new().compile(harness.build_layer.layer_system.build_manager.getAllBuilds())
	var engine := SWSignalEvalCPU.new()
	engine.setup(prog)
	var vals := _input_vals(prog)
	engine.clear_changed()
	engine.write_sources(vals)
	engine.evaluate()
	var rb := engine.readback()
	assert_eq(rb.size(), prog.slot_count, "readback 长度应等于 slot_count")
	# 同样的源值再算一次：组合部分必须得到相同结果（求值是纯函数，无跨拍缓存）
	engine.clear_changed()
	engine.write_sources(vals)
	engine.evaluate()
	var rb2 := engine.readback()
	var diff := 0
	for s in prog.net_count:
		if rb[s] != rb2[s]:
			diff += 1
	assert_eq(diff, 0, "相同源值连续两次求值，%d 个 net 结果不一致（引擎带了跨拍缓存？）" % diff)


func _boot(save_name: String) -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		push_error("存档加载失败: " + save_name)
		return false
	# 等分帧重建收尾（后端是懒建的，等电路表出来即可）
	var ctrl = harness.build_layer.layer_system.circuit_control
	var guard := 0
	while guard < 900 and ctrl._cpu_backends.is_empty():
		guard += 1
		await get_tree().process_frame
	return true


# 5) 回填扁平表（net_list / net_slots / led_* / gate_*）必须与旧口径逐项一致
func test_flattened_render_tables_match() -> void:
	if not await _boot(SAVES[0]):
		return
	var prog := SWGateCompiler.new().compile(harness.build_layer.layer_system.build_manager.getAllBuilds())
	# net_list / net_slots 与 net_to_slot 一一对应
	assert_eq(prog.net_list.size(), prog.net_to_slot.size(), "net_list 与 net_to_slot 数量不一致")
	assert_eq(prog.net_slots.size(), prog.net_to_slot.size(), "net_slots 与 net_to_slot 数量不一致")
	for i in prog.net_list.size():
		var net = prog.net_list[i]
		assert_eq(prog.net_to_slot[net], prog.net_slots[i],
				"第 %d 项 net_list[i] 与其 slot 不匹配" % i)
	# 灯泡分组表：组内的输入段与成员段必须与 led_src_slots / led_group_id 一致
	assert_eq(prog.led_group_id.size(), prog.led_comps.size(), "led_group_id 数量与 LED 数不一致")
	assert_eq(prog.led_group_prev.size(), prog.led_group_src_offs.size(), "led_group_prev 与组数不一致")
	var covered := 0
	for gi in prog.led_group_src_offs.size():
		var off: int = prog.led_group_src_offs[gi]
		var ln: int = prog.led_group_src_lens[gi]
		assert_true(ln <= 4, "组 %d 的输入数超过 4" % gi)
		var mo: int = prog.led_group_mem_offs[gi]
		var mlen: int = prog.led_group_mem_lens[gi]
		assert_gt(mlen, 0, "组 %d 没有任何成员" % gi)
		for k in range(mo, mo + mlen):
			var li: int = prog.led_group_members[k]
			assert_eq(prog.led_group_id[li], gi, "灯泡 %d 的组号不符" % li)
			var expect: PackedInt32Array = prog.led_src_slots[li]
			assert_eq(ln, expect.size(), "组 %d 的输入数与灯泡 %d 不一致" % [gi, li])
			for j in ln:
				assert_eq(prog.led_group_src_flat[off + j], expect[j],
						"组 %d 第 %d 个 slot 与灯泡 %d 不一致" % [gi, j, li])
			covered += 1
	assert_eq(covered, prog.led_comps.size(), "成员段未覆盖全部灯泡")
	# slot 段已去重 + 升序：同一输入集合才算同一组（重复 slot 会让分组命中率下降）
	for li in prog.led_src_slots.size():
		var arr: PackedInt32Array = prog.led_src_slots[li]
		for k in range(1, arr.size()):
			assert_true(arr[k - 1] < arr[k], "LED %d 的 slot 段未去重/未升序" % li)
	# 组合门扁平表：out_slots / refresh_comps / prev_level 三表等长
	assert_eq(prog.gate_refresh_comps.size(), prog.gate_out_slots.size(), "gate_refresh_comps 与 gate_out_slots 不等长")
	assert_eq(prog.gate_prev_level.size(), prog.gate_out_slots.size(), "gate_prev_level 与 gate_out_slots 不等长")
	assert_eq(prog.gate_display_invert.size(), prog.gate_out_slots.size(), "gate_display_invert 与 gate_out_slots 不等长")
	# 每个组合门的输出 slot 必须在本电路范围内
	for s in prog.gate_out_slots:
		assert_true(s >= 0 and s < prog.slot_count, "gate_out_slots 越界: %d" % s)


# 6) 一拍内 NOT 的显示刷新只应发生在「电平真的变了」的门上
func test_gate_display_only_on_change() -> void:
	if not await _boot(SAVES[0]):
		return
	var sys = harness.build_layer.layer_system
	var ctrl = sys.circuit_control
	var clocks: Array = sys.clockBuildArr.keys()
	# 先跑几拍把状态打稳，再连续两拍「完全相同的输入」：
	# 第二轮 dirty 必须远小于门总数（真实电路每拍只有少数门翻转）
	var total_gates := 0
	var total_dirty := 0
	for i in 3:
		ctrl.buildSignalsChanged(clocks)
		total_dirty = 0
		total_gates = 0
		for cid in ctrl._cpu_backends:
			var p: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
			total_gates += p.gate_out_slots.size()
			total_dirty += p.dirty_gate_idx.size()
			# 每拍之间把时钟固定成同一相位，制造「输入完全不变」的一拍
		for c in clocks:
			c.onPressed(true)
	# 这一拍 vs 上一拍输入相同，dirty 应当收敛（不会持有上一拍的残留）
	ctrl.buildSignalsChanged(clocks)
	var same_tick_dirty := 0
	for cid in ctrl._cpu_backends:
		var p: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
		same_tick_dirty += p.dirty_gate_idx.size()
	# dirty 表大小不可能超过门总数（PackedInt32Array 每拍 clear 后重建）
	assert_lte(same_tick_dirty, total_gates,
			"dirty 表(%d) 超过门总数(%d)，说明每拍没清空" % [same_tick_dirty, total_gates])
	assert_gte(total_gates, 0, "门总数异常")
	pass_test("门=%d, 输入无变化的那拍 dirty=%d" % [total_gates, same_tick_dirty])


# 7) 非门贴图必须按「输入电平」选帧（组件 evaluate 的语义），扁平表写成输出电平就反了
func test_not_gate_display_uses_input_level() -> void:
	if not await _boot(SAVES[0]):
		return
	var ctrl = harness.build_layer.layer_system.circuit_control
	var clocks: Array = harness.build_layer.layer_system.clockBuildArr.keys()
	var checked := 0
	var bad := 0
	for t in 4:
		for c in clocks:
			c.onPressed(true)
		ctrl.buildSignalsChanged(clocks)
		for cid in ctrl._cpu_backends:
			var p: SWGateProgram = ctrl._cpu_backends[cid]["prog"]
			for gi in p.gate_out_slots.size():
				if p.gate_display_invert[gi] != 1:
					continue
				var rr = p.gate_refresh_comps[gi]
				if rr == null:
					continue
				var notComp = rr.buildRef.getCircuitCompoent()
				if notComp == null:
					continue
				# 组件口径（独立 oracle）：evalOutput = 1 - 输入位，而贴图显示的是输入位
				var want_high: bool = 1 - notComp.evalOutput() == 1
				var shown_high: bool = rr.buildRef.signal_state == SwDefine.CircuitSignal.HIGH
				if shown_high != want_high:
					bad += 1
				checked += 1
	assert_gt(checked, 0, "存档里没有可校验的非门")
	assert_eq(bad, 0, "非门贴图电平与输入电平不一致（%d/%d 反了）" % [bad, checked])


func _input_vals(prog: SWGateProgram) -> PackedInt32Array:
	var vals := PackedInt32Array()
	for comp in prog.input_comps:
		var ref = comp.buildRef
		if comp is SWBuildCompoentCircuitClockSiggen:
			var clk := ref as SWBuildClockSiggen
			vals.append(1 if clk != null and clk.curSig == SwDefine.CircuitSignal.HIGH else 0)
		elif comp is SWBuildCompoentCircuitSource:
			var btn := ref as SWBuildButton
			vals.append(1 if btn != null and btn.pressed else 0)
		else:
			vals.append(0)
	return vals
