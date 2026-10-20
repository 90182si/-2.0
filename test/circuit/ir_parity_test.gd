extends GutTest
# T2.5 双跑对拍：IR（useIR=true）与表达式树（useIR=false）在相同事件序列下逐拍零差异。
#
# 方法：
# - 每个存档各跑两轮完整会话（boot → 加载 → 手动驱动事件 → 快照 → shutdown），
#   保证两轮初始状态与事件序列完全一致；
# - 时钟 tick 通过手动调用 clockBuildArr 的 onPressed + buildSignalChanged 驱动，
#   并清空 clockBuildArr 屏蔽 _process 自动 tick，使事件序列确定；
# - 快照 = 全部建筑显示电平（电线按其 net 现取，见 getDisplaySignal）+ 全部 net curSignal + 寄存器 qState（按坐标/建筑排序，两轮可比）。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_ADDER := "加法器3"
const SAVE_COUNTER := "计数器2"
const CLOCK_TICK_ROUNDS := 24
const MAX_SWITCH_EVENTS := 6

# ── 用例 1：纯组合 + 电线密集（加法器） ──
func test_parity_adder_save() -> void:
	await _assert_parity(SAVE_ADDER, false, true)

# ── 用例 2：含寄存器时序（计数器） ──
func test_parity_counter_save() -> void:
	await _assert_parity(SAVE_COUNTER, false, true)

# ── 用例 2b：T2.8 拍内合并（beginTick/endTick）与逐事件 push 结果一致 ──
func test_parity_tick_batch_matches_per_event() -> void:
	await _assert_parity(SAVE_COUNTER, true, true, false, true)
	await _assert_parity(SAVE_ADDER, true, true, false, true)

# ── 用例 2c：Phase 2 变更定向求值与「整段重跑 + Pass A BFS」逐拍零差异 ──
func test_parity_change_directed_matches_full_segment() -> void:
	await _assert_parity(SAVE_COUNTER, true, true, true, true, true, false)
	await _assert_parity(SAVE_ADDER, true, true, true, true, true, false)

# ── 用例 2c2：开关全亮下计数器必须真的在数，且变更定向与整段重跑、原生逐拍一致 ──
# 前面的用例都跑在「开关全灭」的存档上：加数=0 → D=Q+0=Q → 计数器天然静止，
# 那种轨迹里零差异是必然结果，掩盖了 Phase 2 变更定向漏播寄存器状态叶的 bug。
func test_parity_counting_counter_matches() -> void:
	var cd: Array = await _capture_trace(SAVE_COUNTER, true, false, true, false, true)
	if cd.is_empty():
		pending("存档不存在，跳过: " + SAVE_COUNTER)
		return
	_assert_ticks_move(cd, "IR 变更定向")
	var full: Array = await _capture_trace(SAVE_COUNTER, true, false, false, false, true)
	_compare_traces(cd, full, SAVE_COUNTER + "（开关全亮：变更定向 vs 整段重跑）")
	if ClassDB.class_exists("SWBoolEval"):
		var nat: Array = await _capture_trace(SAVE_COUNTER, true, false, true, true, true)
		_compare_traces(cd, nat, SAVE_COUNTER + "（开关全亮：GDScript vs 原生）")

## 时钟打拍段的快照必须至少出现两种状态，否则这条轨迹根本没在数，后面的零差异没有意义
func _assert_ticks_move(trace: Array, label: String) -> void:
	var seen: Dictionary = {}
	var tick_n: int = 0
	for row: String in trace:
		if not row.begins_with("tick"):
			continue
		tick_n += 1
		seen[row] = true
	assert_gt(tick_n, 0, "%s 轨迹里没有时钟打拍快照" % label)
	assert_gt(seen.size(), 1, "%s 时钟打拍期间状态从未变化（计数器没在数，对拍等于空转）" % label)

# ── 用例 2e：Phase 4 原生求值（SWBoolEval）与 GDScript 求值逐拍零差异 ──
func test_parity_native_matches_gdscript_eval() -> void:
	if not ClassDB.class_exists("SWBoolEval"):
		pending("GDExtension 未加载（缺 libsw_circuit_native），跳过原生对拍")
		return
	for save_name: String in [SAVE_COUNTER, SAVE_ADDER]:
		var gd: Array = await _capture_trace(save_name, true, false, true, false)
		if gd.is_empty():
			pending("存档不存在，跳过: " + save_name)
			continue
		var nat: Array = await _capture_trace(save_name, true, false, true, true)
		assert_false(nat.is_empty(), "原生轮次未产生轨迹: " + save_name)
		_compare_traces(gd, nat, save_name + "（GDScript 变更定向 vs 原生变更定向）")
		# 整段重跑路径同样要过原生（evaluate_all / evaluate_span，含组合环段的 iters>1 不动点迭代）
		var gd_full: Array = await _capture_trace(save_name, true, false, false, false)
		var nat_full: Array = await _capture_trace(save_name, true, false, false, true)
		_compare_traces(gd_full, nat_full, save_name + "（GDScript 整段 vs 原生整段）")

# ── 用例 2d：变更定向确实少跑指令，且单次事件耗时同步下降 ──
func test_change_directed_evaluates_fewer_instructions() -> void:
	const ROUNDS := 24  # 每行 24 轮 × 16 个时钟事件，压掉会话启动与首事件 warm-up 噪声
	var full: Dictionary = await _measure_events(SAVE_COUNTER, true, false, ROUNDS)
	var cd: Dictionary = await _measure_events(SAVE_COUNTER, true, true, ROUNDS)
	var tree: Dictionary = await _measure_events(SAVE_COUNTER, false, false, ROUNDS)
	var nat: Dictionary = await _measure_events(SAVE_COUNTER, true, true, ROUNDS, true)
	var full_nat: Dictionary = await _measure_events(SAVE_COUNTER, true, false, ROUNDS, true)
	if full.is_empty():
		pending("存档不存在或没有时钟事件，跳过: " + SAVE_COUNTER)
		return
	assert_lt(cd["insts"], full["insts"], "变更定向应少执行指令")
	assert_lt(float(cd["insts"]) / float(full["insts"]), 0.6, "变更定向只省了 %.0f%% 指令，可能没走快路径" % (100.0 * (1.0 - float(cd["insts"]) / float(full["insts"]))))
	assert_eq(nat["insts"], cd["insts"], "原生路径执行的指令数应与 GDScript 变更定向一致")
	assert_lt(full_nat["eval_ms"], full["eval_ms"], "原生整段求值应快于 GDScript 整段求值")
	for row: Array in [
		["树 pull", tree], ["IR 整段重跑", full], ["IR 整段+原生", full_nat],
		["IR 变更定向", cd], ["IR 变更定向+原生", nat],
	]:
		var d: Dictionary = row[1]
		if d.is_empty():
			continue
		print("[CD] %-16s 每次事件指令 %8.1f   求值 %.4fms   整条事件 %.4fms" % [row[0], d["insts"], d["eval_ms"], d["ms"]])

## 跑重复事件序列，返回 {"insts": 每次事件平均指令数, "ms": 每次事件平均毫秒}；存档缺失返回 {}
func _measure_events(save_name: String, ir: bool, cd: bool, rounds: int, native: bool = false) -> Dictionary:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	control.useIR = ir
	control.useChangeDirected = cd
	control.useNativeEval = native
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		await _dispose_harness(harness)
		return {}
	var clocks: Array = harness.build_layer.clockBuildArr.keys()
	harness.build_layer.clockBuildArr.clear()
	if clocks.is_empty():
		await _dispose_harness(harness)
		return {}
	var before: int = SWBoolProgram.s_eval_inst_count
	var before_us: int = SWBoolProgram.s_eval_usec
	var t0: int = Time.get_ticks_usec()
	for r in range(rounds):
		control.beginTick()
		for clock in clocks:
			_fire_event(harness, clock, true)
		control.endTick()
	var us: int = Time.get_ticks_usec() - t0
	var insts: int = SWBoolProgram.s_eval_inst_count - before
	var eval_us: int = SWBoolProgram.s_eval_usec - before_us
	await _dispose_harness(harness)
	var events: int = rounds * clocks.size()
	return {
		"insts": float(insts) / events,
		"ms": float(us) / 1000.0 / events,
		"eval_ms": float(eval_us) / 1000.0 / events,
	}

## 覆盖率补齐：两份存档的段都是 iters=1（Kosaraju 没检出组合环），
## 上面用例走不到 iters>1 的多趟不动点分支——这里手工造一个「三格反相环」段直接对拍，
## 它每趟结果都在翻转、永不收敛，所以收敛趟数与 GDScript 是否一致会被完整暴露。
func test_native_matches_gdscript_on_cyclic_span() -> void:
	if not ClassDB.class_exists("SWBoolEval"):
		pending("GDExtension 未加载，跳过组合环对拍")
		return
	for iters: int in [1, 2, 5, 6]:
		var gd: SWBoolProgram = _make_ring_program(false, iters)
		var nat: SWBoolProgram = _make_ring_program(true, iters)
		# 防「假对拍」：dll 掉了时 class_exists 已经 pending 拦住，但 instantiate 失败也会
		# 让 _native 保持 null，那时两边都跑 GDScript，比出来必然一致却毫无意义
		assert_true(nat._native != null, "iters=%d 原生后端没生效，这轮变成 GDScript 自比" % iters)
		assert_true(gd._native == null, "iters=%d GDScript 基准轮不该挂上原生后端" % iters)
		var gd_before: int = SWBoolProgram.s_eval_inst_count
		gd.evaluate()
		var gd_insts: int = SWBoolProgram.s_eval_inst_count - gd_before
		var nat_before: int = SWBoolProgram.s_eval_inst_count
		nat.evaluate()
		var nat_insts: int = SWBoolProgram.s_eval_inst_count - nat_before
		var gd_vals: Array = []
		var nat_vals: Array = []
		for s in range(3):
			gd_vals.append(gd.get_slot_value(s))
			nat_vals.append(nat.get_slot_value(s))
		assert_eq(nat_vals, gd_vals, "iters=%d 三格反相环收敛值应一致（gd=%s nat=%s）" % [iters, str(gd_vals), str(nat_vals)])
		assert_eq(nat_insts, gd_insts, "iters=%d 执行指令数应一致（gd=%d nat=%d），否则趟数口径不同" % [iters, gd_insts, nat_insts])
		var gd_changed: Array = gd.changed_slots.keys()
		var nat_changed: Array = nat.changed_slots.keys()
		gd_changed.sort()
		nat_changed.sort()
		assert_eq(nat_changed, gd_changed, "iters=%d 变化槽集合应一致" % iters)

## 手工搭一条 3 指令的组合环段：slot0 = ~slot2, slot1 = ~slot0, slot2 = ~slot1
## native=false 时实例化后立刻关开关，build_indices 便不会挂上原生后端
func _make_ring_program(native: bool, iters: int) -> SWBoolProgram:
	var p := SWBoolProgram.new()
	p.useNativeEval = native
	p.op_arr = PackedInt32Array([SWBoolProgram.OP_NOT, SWBoolProgram.OP_NOT, SWBoolProgram.OP_NOT])
	p.dst_arr = PackedInt32Array([0, 1, 2])
	p.a_arr = PackedInt32Array([2, 0, 1])
	p.b_arr = PackedInt32Array([0, 0, 0])
	p.segments = {1: {"start": 0, "end": 3, "builds": [], "iters": iters}}
	p.build_indices()
	return p

# ── 用例 0（诊断）：tree-vs-tree 自对拍，验证测试方法学本身确定性 ──
func test_parity_selfcheck_tree_vs_tree() -> void:
	await _assert_parity(SAVE_ADDER, false, false)

# ── 用例 3：useIR=true 时事件路径不再调用树求值 EvalStruct ──
func test_ir_tick_bypasses_evalstruct() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	harness.build_layer.sw_circuit_control.useIR = true
	var data: Dictionary = await harness.load_save(SAVE_ADDER)
	if data.is_empty():
		pending("存档不存在，跳过: " + SAVE_ADDER)
		return
	# 关掉自动 tick，只走手动事件
	var clocks: Array = harness.build_layer.clockBuildArr.keys()
	harness.build_layer.clockBuildArr.clear()
	var switches := _collect_clickable(harness.build_layer.sw_build_manager)
	if switches.is_empty():
		pending("存档没有可点击建筑，跳过")
		return
	var sw = switches[0]
	# 先做一次事件让 IR 路径热起来（不计入测量）
	_fire_event(harness, sw, true)
	var before: int = SwCommon.evalStructCallCount
	for on: bool in [false, true, false]:
		_fire_event(harness, sw, on)
	for i in range(CLOCK_TICK_ROUNDS):
		for clock in clocks:
			_fire_event(harness, clock, true)
	var delta: int = SwCommon.evalStructCallCount - before
	assert_eq(delta, 0, "useIR=true 时事件/tick 路径 EvalStruct 调用应归零，实际 %d 次" % delta)
	harness.shutdown_game()

# ── 核心流程 ─────────────────────────────────────────────────────

func _assert_parity(save_name: String, irA: bool, irB: bool, batchA: bool = false, batchB: bool = false, cdA: bool = true, cdB: bool = true) -> void:
	var trace_tree: Array = await _capture_trace(save_name, irA, batchA, cdA)
	if trace_tree.is_empty():
		pending("存档不存在，跳过: " + save_name)
		return
	var trace_ir: Array = await _capture_trace(save_name, irB, batchB, cdB)
	assert_false(trace_ir.is_empty(), "IR 轮次未产生轨迹（存档加载失败？）: " + save_name)
	_compare_traces(trace_tree, trace_ir, save_name)

## 逐拍字符串快照对比：两轮拍数一致且每拍 token 全等
func _compare_traces(trace_a: Array, trace_b: Array, label: String) -> void:
	assert_eq(trace_b.size(), trace_a.size(),
		"%s 两轮拍数不一致（A=%d B=%d）" % [label, trace_a.size(), trace_b.size()])
	var diffs: int = 0
	var shown: int = 0
	for i in range(mini(trace_b.size(), trace_a.size())):
		var a: String = trace_a[i]
		var b: String = trace_b[i]
		if a == b:
			continue
		diffs += 1
		if shown >= 6:
			continue
		shown += 1
		print(_diff_tokens(i, a, b))
	assert_eq(diffs, 0, "%s 双跑对拍出现 %d 拍差异（详见 print）" % [label, diffs])

## 逐 token 对比同一拍的两轮快照，返回所有不一致 token（最多 30 个）的诊断串
func _diff_tokens(frame: int, a: String, b: String) -> String:
	var ta: PackedStringArray = a.split(";")
	var tb: PackedStringArray = b.split(";")
	var n: int = mini(ta.size(), tb.size())
	var out: Array[String] = []
	for k in range(n):
		if ta[k] != tb[k]:
			out.append("  tk%d tree=%s | ir=%s" % [k, ta[k], tb[k]])
			if out.size() >= 30:
				break
	return "拍%d 差异(%d+):\n%s" % [frame, out.size(), "\n".join(out)]

## 完整会话：boot →（可选开 IR）→ 加载 → 手动事件序列 → 每步快照 → 完全释放
## 关键：本函数自行管理 harness 生命周期（不用 add_child_autofree），
## 确保两轮 _capture_trace 串行时上一轮场景/静态引用已彻底释放，避免双会话共存导致的 freed-instance。
func _capture_trace(save_name: String, ir: bool, batched: bool = false, cd: bool = true, native: bool = false, lights_on: bool = false) -> Array:
	var trace: Array = []
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	control.useIR = ir
	# Phase 2 回退开关：cd=false 强制走「整段重跑 + Pass A BFS」旧路径
	control.useChangeDirected = cd
	# Phase 4 回退开关：native=false 让求值循环留在 GDScript 路径（作为对拍基准）
	control.useNativeEval = native
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		await _dispose_harness(harness)
		return trace
	# 防「假对拍」：要求原生后端的轮次必须真的挂上了 SWBoolEval，否则两轮都是 GDScript，比出来必然一致
	if native and control.boolProgram != null:
		assert_true(control.boolProgram._native != null, "要求原生后端但 _native 为空（dll 缺失或 instantiate 失败）: " + save_name)
	# 屏蔽自动 tick，改用手动驱动保证两轮事件序列一致
	var clocks: Array = harness.build_layer.clockBuildArr.keys()
	harness.build_layer.clockBuildArr.clear()

	trace.append(_snapshot(harness, "load"))

	# 可点击建筑（开关/按钮/时钟）；事件序列分两种口径，见下
	var clickables: Array = _collect_clickable(harness.build_layer.sw_build_manager)
	# 计数器存档的开关默认全灭：加数为 0 时 D=Q+0=Q，"一直保持 0"是正确行为，
	# 这种静止轨迹下变更定向与整段重跑必然零差异，什么也证明不了。
	# lights_on 先把全部开关拨亮，让 24 拍时钟真的把 qState 逐级传下去。
	if lights_on:
		var light_n := 0
		for lb in clickables:
			_fire_event(harness, lb, true)
			light_n += 1
			trace.append(_snapshot(harness, "light%d" % light_n))
	else:
		# 开关事件：依次打开前若干个（含开关/按钮），再依次关闭
		var fired: Array = []
		for i in range(mini(MAX_SWITCH_EVENTS, clickables.size())):
			var b = clickables[i]
			var on: bool = not _is_clock(b)
			_fire_event(harness, b, on)
			fired.append([b, on])
			trace.append(_snapshot(harness, "switch%d_on=%s" % [i, str(on)]))
		for item: Array in fired:
			_fire_event(harness, item[0], false)
			trace.append(_snapshot(harness, "switch_off"))

	# 时钟打拍：所有时钟一起翻转 CLOCK_TICK_ROUNDS 轮
	# batched=true 时按运行时 _process 的形状把整拍事件包进 beginTick/endTick，
	# 与逐事件 push 对照，验证「电线写回 + signalTex 上色合并到拍尾」不改变可观测状态
	for i in range(CLOCK_TICK_ROUNDS):
		if batched:
			control.beginTick()
		for clock in clocks:
			_fire_event(harness, clock, true)
		if batched:
			control.endTick()
		trace.append(_snapshot(harness, "tick%d" % i))

	await _dispose_harness(harness)
	return trace

## 彻底释放一个 harness（含其游戏场景），并等两帧让 queue_free 生效 + _exit_tree 清理静态登记
func _dispose_harness(harness) -> void:
	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()

func _is_clock(build) -> bool:
	return build is SWBuildClockSiggen

## 复刻运行时事件：onPressed + buildSignalChanged（与 _process/点击路径同款）
func _fire_event(harness, build: SWBuildItemDefine, pressed: bool) -> void:
	build.onPressed(pressed)
	harness.build_layer.sw_circuit_control.buildSignalChanged(build)

## 确定性快照：比较可观测功能态——所有非争议建筑的显示电平 + 寄存器 qState + 单驱动 net curSignal。
## 排除项（争议 net）：多驱动（getDrivers().size()>=2）的 wired-AND 争议 net，以及挂在这些 net 上的电线建筑。
## 理由：树模型里争议 net 的 curSignal 由 pull 副作用“最后调用 getValue 的驱动者胜”决定，是无确定逻辑值的写入顺序产物
## （既非 AND 也非固定某驱动）；消费者经表达式/slot 读到的是确定的 AND 结果（由 expr-node slot==tree-pull 断言保障）。
## 电线仅展示其 net 电平，争议 net 上的电线视觉随之不确定，故一并排除；LED/门/寄存器等功能态全部纳入比对。
func _snapshot(harness, label: String) -> String:
	var parts: Array[String] = []
	var builds: Array = harness.build_layer.sw_build_manager.getAllBuilds()
	var sorted_builds: Array = builds.duplicate()
	sorted_builds.sort_custom(func(x, y): return x.buildAxisPos < y.buildAxisPos)
	# 先收集争议 net（多驱动）
	var contention: Dictionary = {}
	var nets: Dictionary = {}
	for b: SWBuildItemDefine in sorted_builds:
		var comp0: SWBuildCompoentCircuit = b.getCircuitCompoent()
		if comp0 == null:
			continue
		for net: SWNet in comp0.pinNetMap.values():
			if net == null:
				continue
			nets[net] = true
			if net.getDrivers().size() >= 2:
				contention[net] = true
	for b: SWBuildItemDefine in sorted_builds:
		var comp: SWBuildCompoentCircuit = b.getCircuitCompoent()
		# 电线视觉排除：①任一引脚 net 为争议 net（多驱）；②电线跨 ≥2 条独立 net（如 WIRE_BRIDGE 的
		# v_net/h_net）且它们电平不一致——一个显示 token 无法同时表达两条交叉 net 的电平
		# （getDisplaySignal 对交叉电线固定取 v_net），与争议 net 同理排除。
		# 两条 net 各自的 curSignal 仍作为 N token 独立比对，功能覆盖不受影响。
		var skip_wire := false
		if comp != null and SwCommon.IsWireBuild(b):
			var wire_levels: Dictionary = {}
			for net: SWNet in comp.pinNetMap.values():
				if net == null:
					continue
				if contention.has(net):
					skip_wire = true
					break
				wire_levels[net.curSignal] = true
			if not skip_wire and wire_levels.size() > 1:
				skip_wire = true
		if not skip_wire:
			var ct_name := _ct_name(b)
			parts.append("B%s:%d:%s:%s" % [str(b.buildAxisPos), b.rotation, ct_name, str(b.getDisplaySignal())])
		if comp == null:
			continue
		var reg := comp as SWBuildCompoentCircuitRegister
		if reg != null:
			parts.append("Q%s:%s" % [str(b.buildAxisPos), str(reg.qState)])
	var sorted_nets: Array = nets.keys()
	# net 无天然坐标，用 netId 保证两轮顺序一致（同一存档两轮重建路径相同，netId 分配一致）
	sorted_nets.sort_custom(func(x, y): return x.netId < y.netId)
	for net: SWNet in sorted_nets:
		if contention.has(net):
			continue
		parts.append("N%d:%s" % [net.netId, str(net.curSignal)])
	return label + "|" + ";".join(parts)

## 组件类型名（诊断用）
func _ct_name(b: SWBuildItemDefine) -> String:
	if b.buildDefine == null:
		return "?"
	return str(b.buildDefine.circuit_component_type)

## 收集可点击建筑（按钮/开关），按坐标排序保证确定性
func _collect_clickable(bm: SWBuildManager) -> Array:
	var result: Array = []
	for b: SWBuildItemDefine in bm.getAllBuilds():
		var ct = b.buildDefine.circuit_component_type
		if ct == SwDefine.CircuitComponentType.SWITCH or ct == SwDefine.CircuitComponentType.BUTTON:
			result.append(b)
	result.sort_custom(func(x, y): return x.buildAxisPos < y.buildAxisPos)
	return result
