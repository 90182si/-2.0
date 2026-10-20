extends GutTest
# T2.5 双跑对拍：IR（useIR=true）与表达式树（useIR=false）在相同事件序列下逐拍零差异。
#
# 方法：
# - 每个存档各跑两轮完整会话（boot → 加载 → 手动驱动事件 → 快照 → shutdown），
#   保证两轮初始状态与事件序列完全一致；
# - 时钟 tick 通过手动调用 clockBuildArr 的 onPressed + buildSignalChanged 驱动，
#   并清空 clockBuildArr 屏蔽 _process 自动 tick，使事件序列确定；
# - 快照 = 全部建筑 signal_state + 全部 net curSignal + 寄存器 qState（按坐标/建筑排序，两轮可比）。

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

func _assert_parity(save_name: String, irA: bool, irB: bool) -> void:
	var trace_tree: Array = await _capture_trace(save_name, irA)
	if trace_tree.is_empty():
		pending("存档不存在，跳过: " + save_name)
		return
	var trace_ir: Array = await _capture_trace(save_name, irB)
	assert_false(trace_ir.is_empty(), "IR 轮次未产生轨迹（存档加载失败？）: " + save_name)
	assert_eq(trace_ir.size(), trace_tree.size(),
		"两拍数不一致（tree=%d ir=%d）" % [trace_tree.size(), trace_ir.size()])
	var diffs: int = 0
	var shown: int = 0
	for i in range(mini(trace_ir.size(), trace_tree.size())):
		var a: String = trace_tree[i]
		var b: String = trace_ir[i]
		if a == b:
			continue
		diffs += 1
		if shown >= 6:
			continue
		shown += 1
		print(_diff_tokens(i, a, b))
	assert_eq(diffs, 0, "双跑对拍出现 %d 拍差异（详见 print）" % diffs)

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
func _capture_trace(save_name: String, ir: bool) -> Array:
	var trace: Array = []
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	control.useIR = ir
	var data: Dictionary = await harness.load_save(save_name)
	if data.is_empty():
		await _dispose_harness(harness)
		return trace
	# 屏蔽自动 tick，改用手动驱动保证两轮事件序列一致
	var clocks: Array = harness.build_layer.clockBuildArr.keys()
	harness.build_layer.clockBuildArr.clear()

	trace.append(_snapshot(harness, "load"))

	# 开关事件：依次打开前若干个（含开关/按钮），再依次关闭
	var clickables: Array = _collect_clickable(harness.build_layer.sw_build_manager)
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
	for i in range(CLOCK_TICK_ROUNDS):
		for clock in clocks:
			_fire_event(harness, clock, true)
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

## 确定性快照：比较可观测功能态——所有非争议建筑的 signal_state + 寄存器 qState + 单驱动 net curSignal。
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
		# v_net/h_net）且它们电平不一致——单一 signal_state 字段无法同时表达两条交叉 net，
		# 显示为“最后写回者胜”的视觉歧义（树 pull 与 IR push 写回次序不同），与争议 net 同理排除。
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
			parts.append("B%s:%d:%s:%s" % [str(b.buildAxisPos), b.rotation, ct_name, str(b.signal_state)])
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
