extends GutTest
# T1.10 对拍：SWGateCompiler 生成的 op_list + GPU 求值引擎 vs 现有 CPU 树求值。
# 逐拍比对 net.curSignal（CPU 真源）与 GPU/模拟 slot 结果，任何不一致都说明
# 编译器或引擎与树求值语义有偏离（多驱动线与/悬空/寄存器锁存/NOT 链/环路）。
#   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/circuit/test_gate_parity.gd -gexit
# 无 RenderingDevice 环境自动退回纯 CPU 模拟（同样验证编译器语义）。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE := "16x计数器"
const SAVES := ["16x计数器", "计数器2", "测试寄存器"]

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func test_compiler_outputs_sane_program() -> void:
	if not await _boot(SAVE):
		return
	var prog := SWGateCompiler.new().compile(harness.build_layer.layer_system.build_manager.getAllBuilds())
	assert_gt(prog.gate_count, 0, "编译产物没有任何 gate")
	assert_gt(prog.slot_count, 0, "slot 数为 0")
	assert_gt(prog.level_count, 0, "拓扑层数为 0")
	assert_eq(prog.input_slots.size(), prog.input_comps.size(), "源 slot 与源组件数不一致")
	# gate 按 level 升序排列
	var prev_lv := -1
	var sorted := true
	for gi in prog.gate_count:
		var lv: int = prog.gates[gi * SWGateProgram.STRIDE + 2]
		if lv < prev_lv:
			sorted = false
			break
		prev_lv = lv
	assert_true(sorted, "gate 未按 level 升序")

func test_gpu_engine_matches_cpu_16x() -> void:
	await _parity_loop(SAVE, true)

func test_gpu_engine_matches_cpu_counter2() -> void:
	await _parity_loop("计数器2", true)

func test_cpu_sim_matches_cpu_16x() -> void:
	await _parity_loop(SAVE, false)

func test_cpu_sim_matches_cpu_counter2() -> void:
	await _parity_loop("计数器2", false)

func test_gpu_backend_integration_fallback() -> void:
	# M3 集成：buildSignalsChanged 分流 GPU 后端；无 RenderingDevice 环境（headless）
	# 引擎 broken → 自动回退 CPU 增量路径。验证回退后求值/标脏行为不破坏。
	if not await _boot(SAVE):
		return
	var sys = harness.build_layer.layer_system
	var cc = sys.circuit_control
	cc.gpu_backend_enabled = true
	# 本用例断言「首拍有标脏 net」——net 标脏发生在回填阶段。
	# 这里显式写死完整回填（默认已是 true），保证默认值变动不改变本用例的覆盖面。
	cc.backfill_net_signal = true
	cc.backfill_gate_display = true
	cc.clear_cpu_backends()
	var clocks: Array = sys.clockBuildArr.keys()
	assert_false(clocks.is_empty(), "存档没有时钟")
	for build in clocks:
		build.onPressed(true)
	var changed: Array = cc.buildSignalsChanged(clocks)
	var dirty: Dictionary = cc.takeDirtyNets()
	assert_true(changed.size() > 0 or not dirty.is_empty(),
			"GPU 回退后首拍无任何求值/标脏（计数器应照常翻转）")
	for i in 3:
		for build in clocks:
			build.onPressed(true)
		cc.buildSignalsChanged(clocks)
	assert_true(true, "GPU 回退路径连续多拍无异常")


func _boot(save_name: String) -> bool:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		push_error("存档加载失败: " + save_name)
		return false
	return true


# 核心对拍：
# - use_gpu=true：GPU 引擎 readback vs 同步参考（_simulate，纯 GDScript 复刻引擎语义）——验证引擎实现；
#   要求逐拍全等（两者同一同步模型）。headless 无 RD 时引擎 broken 会跳过。
# - use_gpu=false：_simulate vs CPU 树求值（net.curSignal）——验证编译器生成的 op_list 语义。
#   CPU 寄存器是"求值时刻采样立即生效"（异步），GPU 是"帧末锁存"（同步，SPEC 规范）：
#   上升沿拍允许一拍差异（预期），下降沿/无采样拍必须逐 net 全等（组合语义验证）。
func _parity_loop(save_name: String, use_gpu: bool) -> void:
	if not await _boot(save_name):
		return
	var sys = harness.build_layer.layer_system
	var prog := SWGateCompiler.new().compile(sys.build_manager.getAllBuilds())
	if prog.gate_count <= 0:
		fail_test("%s 编译产物为空" % save_name)
		return
	var engine: SWSignalEvalGPU = null
	if use_gpu:
		engine = SWSignalEvalGPU.new()
		engine.setup(prog)
		if engine.is_broken():
			fail_test("%s GPU 引擎初始化失败（RD 不可用？）" % save_name)
			return

	# 初始状态对齐：prev 用当前 net 电平；寄存器 Q/last_clk 用当前 qState/clk 电平
	var prev := PackedInt32Array()
	prev.resize(prog.slot_count)
	prev.fill(0)
	for net in prog.net_to_slot:
		prev[prog.net_to_slot[net]] = 1 if (net as SWNet).curSignal == SwDefine.CircuitSignal.HIGH else 0
	# q comp slot 也进拍前基线（sim 的 a[q] 来自 reg_state，GPU init_prev 需同源）
	for ri in prog.reg_slots.size():
		var reg := prog.reg_comps[ri] as SWBuildCompoentCircuitRegister
		if reg != null:
			prev[prog.reg_slots[ri]] = 1 if reg.qState == SwDefine.CircuitSignal.HIGH else 0
	if engine != null:
		var q := PackedInt32Array()
		var lc := PackedInt32Array()
		for ri in prog.reg_slots.size():
			var reg := prog.reg_comps[ri] as SWBuildCompoentCircuitRegister
			q.append(1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0)
			lc.append(-1 if reg == null or reg.lastClk == SwDefine.CircuitSignal.NONE \
					else (1 if reg.lastClk == SwDefine.CircuitSignal.HIGH else 0))
		engine.init_reg_state(q, lc)
		engine.init_prev(prev)
	var reg_state := PackedInt32Array()
	reg_state.resize(prog.reg_slots.size() * 2)
	reg_state.fill(0)
	for ri in prog.reg_slots.size():
		var reg := prog.reg_comps[ri] as SWBuildCompoentCircuitRegister
		if reg == null:
			push_error("reg_comps[%d] 不是寄存器: %s" % [ri,
				str(prog.reg_comps[ri].get_script().resource_path)])
		reg_state[ri * 2] = 1 if reg != null and reg.qState == SwDefine.CircuitSignal.HIGH else 0
		reg_state[ri * 2 + 1] = -1 if reg == null or reg.lastClk == SwDefine.CircuitSignal.NONE \
				else (1 if reg.lastClk == SwDefine.CircuitSignal.HIGH else 0)
	# 诊断：reg_slots 是否含 3063（net#12 的驱动）
	if prog.reg_slots.has(3063):
		var ri: int = prog.reg_slots.find(3063)
		push_warning("reg slot 3063 → ri=%d qState=%d lastClk=%d" % [
			ri, reg_state[ri * 2], reg_state[ri * 2 + 1]])

	var clocks: Array = sys.clockBuildArr.keys()
	var max_mismatch := 0
	var trend := ""
	var prev_vals := PackedInt32Array()   # 上一拍源值：SIM 参考复现 GPU 结果缓冲里的源残留（物理缓冲语义）
	for tick in 48:
		for clk in clocks:
			clk.onPressed(true)
		sys.refresh_signal_chunks(sys.circuit_control.buildSignalsChanged(clocks))

		var vals := _input_vals(prog)
		var detail: Array[String] = []
		var gpu_slots := PackedInt32Array()
		var sim_slots := PackedInt32Array()
		if use_gpu:
			engine.write_sources(vals)
			engine.evaluate()
			gpu_slots = engine.readback()
			var sim := _simulate(prog, vals, prev_vals, prev, reg_state)
			sim_slots = sim["slots"]
			# 同步参考随 GPU 状态推进（prev = GPU 本拍结果 = 下拍拍前；reg_state = 同步锁存结果）
			reg_state = sim["reg_state"]
			prev = gpu_slots
			# GPU 引擎 vs 同步参考：逐拍全等（同一同步模型；源 slot 残留用上一拍 vals 复现）
			var sim_bad := 0
			for s in prog.slot_count:
				if gpu_slots[s] != sim_slots[s]:
					sim_bad += 1
					if sim_bad <= 4:
						detail.append("slot%d gpu=%d ref=%d" % [s, gpu_slots[s], sim_slots[s]])
			assert_eq(sim_bad, 0, "第 %d 拍 %s GPU vs 同步参考不一致（%d slot）：%s" % [
				tick, save_name, sim_bad, ", ".join(detail)])
		else:
			var sim := _simulate(prog, vals, prev_vals, prev, reg_state)
			gpu_slots = sim["slots"]
			reg_state = sim["reg_state"]
			prev = gpu_slots
		# 上一拍源值留给下拍 SIM 参考复现 GPU 结果缓冲里的源残留（物理缓冲语义）
		prev_vals = vals

		var bad := 0
		var rising := false
		for clk in clocks:
			if (clk as SWBuildClockSiggen).curSig == SwDefine.CircuitSignal.HIGH:
				rising = true
				break
		for net in prog.net_to_slot:
			# CPU 增量只沿事件标脏链传播；无事件静态源（如已按住的按钮）的输出 net 保持加载快照，
			# GPU 全量按源当前状态重算——预期差异。只在 CPU 本轮实际重算过的 net 上做语义等价断言。
			if (net as SWNet).sigEpoch != sys.circuit_control._curEpoch:
				continue
			var slot: int = prog.net_to_slot[net]
			var want := 1 if (net as SWNet).curSignal == SwDefine.CircuitSignal.HIGH else 0
			if gpu_slots[slot] != want:
				bad += 1
				if detail.size() < 4:
					var drv_names: Array[String] = []
					for d in (net as SWNet)._driverComps:
						drv_names.append((d as Object).get_script().resource_path.get_file())
					var gate_desc := ""
					for g in prog.gate_count:
						if prog.gates[g * SWGateProgram.STRIDE + 1] == slot:
							var op: int = prog.gates[g * SWGateProgram.STRIDE]
							var lv: int = prog.gates[g * SWGateProgram.STRIDE + 2]
							var n: int = prog.gates[g * SWGateProgram.STRIDE + 3]
							var srcs := ""
							for s in n:
								var sid: int = prog.gates[g * SWGateProgram.STRIDE + 4 + s]
								srcs += "%d@%d " % [sid, gpu_slots[sid]]
							gate_desc = "op=%d lv=%d srcs[%s]" % [op, lv, srcs]
							break
					detail.append("net#%d(lv=%d) gpu=%d cpu=%d drv=%s %s" % [
						(net as SWNet).netId, slot, gpu_slots[slot], want,
						", ".join(drv_names), gate_desc])
		if not rising:
			max_mismatch = maxi(max_mismatch, bad)
		trend += "%d:%d " % [tick, bad]
		if rising:
			# CPU 寄存器采样立即生效（异步），GPU 帧末锁存（同步）——上升沿拍允许一拍滞后
			if bad > 0:
				push_warning("上升沿拍 %d 与 CPU 差 %d 个 net（同步一拍，预期）" % [tick, bad])
		else:
			assert_eq(bad, 0, "第 %d 拍 %s(%s) 求值不一致（%d 个 net）：%s" % [
				tick, save_name, "GPU" if use_gpu else "SIM", bad, ", ".join(detail)])
		if tick == 47:
			push_warning("bad 趋势（每拍不一致数）: %s" % trend)
	assert_eq(max_mismatch, 0, "%s %s 对拍存在不一致" % [save_name, "GPU" if use_gpu else "SIM"])

# 源输入值（顺序 = prog.input_slots）：时钟读 curSig，按钮/开关读 pressed
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
		if ref == null:
			push_warning("input comp buildRef=null: " + (comp as Object).get_script().resource_path)
	return vals


# 纯 GDScript 模拟 GPU 求值语义（逐层 + 双缓冲读旧写新 + 锁存 pass + 锁存后同拍再传播）
func _simulate(prog: SWGateProgram, input_vals: PackedInt32Array,
		prev_vals: PackedInt32Array, prev: PackedInt32Array, reg_state: PackedInt32Array) -> Dictionary:
	var a := prev.duplicate()
	# 寄存器 Q 值（comp slot）从 reg_state 同步进读侧缓冲（组合 pass 直接读 a[q]）
	for i in prog.reg_slots.size():
		a[prog.reg_slots[i]] = reg_state[i * 2]
	for i in input_vals.size():
		a[prog.input_slots[i]] = input_vals[i]
	var b := PackedInt32Array()
	b.resize(prog.slot_count)
	b.fill(0)
	# 复现结果缓冲里的源残留（上一拍 write_sources 值；首拍 prev_vals 为空 = 引擎初始全 0，一致）
	for i in prev_vals.size():
		b[prog.input_slots[i]] = prev_vals[i]
	var slot_lv := _build_slot_lv(prog)
	_run_levels(prog, a, b, slot_lv)
	# 锁存 pass（组合后，读旧值缓冲的拍前 D）
	var q_changed := false
	for ri in prog.reg_slots.size():
		var q := prog.reg_slots[ri]
		var clk := prog.reg_clk_slots[ri]
		var d := prog.reg_d_slots[ri]
		var q_old := reg_state[ri * 2]
		var last_clk := reg_state[ri * 2 + 1]
		var clk_new := _read_slot(a, b, slot_lv, prog.level_count, clk)
		var d_old := a[d]
		if last_clk == 0 and clk_new == 1:
			if q_old != d_old:
				q_changed = true
			q_old = d_old
		reg_state[ri * 2] = q_old
		reg_state[ri * 2 + 1] = clk_new
		# 新 Q 同时写 b（结果缓冲）与 a（读侧）：第二遍组合立即读到
		b[q] = q_old
		a[q] = q_old
	# Q 真的翻了 → 再用新 Q 跑一遍组合（与 GPU 引擎/CPU 引擎同语义）
	if q_changed:
		_run_levels(prog, a, b, slot_lv)
	return {"slots": b, "reg_state": reg_state}


# 按层跑一遍组合求值（读旧写新）
# ---- 注意：这段模拟按 **展平后** 的 prog.gates + 层区间表来跑 ----
# 不能用「遍历未展平的 records」的写法：展平会按 level 重排 gate，
# 模拟必须与引擎走同一张表、同一套层边界，否则环上节点排在最后一层时会错位。
func _run_levels(prog: SWGateProgram, a: PackedInt32Array, b: PackedInt32Array,
		slot_lv: PackedInt32Array) -> void:
	for lv in prog.level_count:
		var start: int = prog.level_starts[lv]
		var cnt: int = prog.level_counts[lv]
		if start < 0:
			continue
		for gi in range(start, start + cnt):
			var base := gi * SWGateProgram.STRIDE
			var op := prog.gates[base]
			var dst := prog.gates[base + 1]
			var n := prog.gates[base + 3]
			var v := 0
			if op == SWGateProgram.OP_NOT:
				v = 1 - _read_slot(a, b, slot_lv, lv, prog.gates[base + 4])
			elif op == SWGateProgram.OP_AND:
				v = 1
				if n <= 0:
					v = 0
				else:
					for k in n:
						v &= _read_slot(a, b, slot_lv, lv, prog.gates[base + 4 + k])
			b[dst] = v


func _read_slot(a: PackedInt32Array, b: PackedInt32Array, slot_lv: PackedInt32Array,
		cur_level: int, s: int) -> int:
	var lv: int = slot_lv[s]
	if lv >= 0 and lv < cur_level:
		return b[s]
	return a[s]


func _build_slot_lv(prog: SWGateProgram) -> PackedInt32Array:
	var slot_lv := PackedInt32Array()
	slot_lv.resize(prog.slot_count)
	slot_lv.fill(-1)
	for gi in prog.gate_count:
		var base := gi * SWGateProgram.STRIDE
		var dst := prog.gates[base + 1]
		if dst >= 0 and dst < prog.slot_count:
			slot_lv[dst] = prog.gates[base + 2]
	return slot_lv
