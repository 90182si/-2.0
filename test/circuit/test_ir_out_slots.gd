extends GutTest
# Task#5 回归测试：
# Fix-4A —— useIR=false（默认）时 updateBuildCircuit 不再编译 IR（boolProgram 保持 null）
# Fix-4B —— OP_OUT 的 dst 使用 slot 索引（不再是指令索引），且目标 net 为输出方向的 net
#   * NOT 门表达式挂在输入侧 key 上，OP_OUT 必须写回 rotation 方向的输出 net
#   * LED / 寄存器输入侧表达式没有输出 net，不应产生 OP_OUT

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_NAME := "加法器3"

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func test_ir_disabled_by_default_and_out_slot_semantics() -> void:
	await harness.boot_game()
	var control: SWCircuitControl = harness.build_layer.sw_circuit_control
	assert_true(control != null, "sw_circuit_control 为 null")
	if control == null:
		return
	var bm: SWBuildManager = harness.build_layer.sw_build_manager

	# ── Fix-4A：默认 useIR=false，加载存档触发 updateBuildCircuit 后不编译 IR ──
	assert_false(control.useIR, "useIR 默认应为 false")
	var data: Dictionary = await harness.load_save(SAVE_NAME)
	if data.is_empty():
		pending("存档不存在，跳过: " + SAVE_NAME)
		return
	assert_null(control.boolProgram, "useIR=false 时不应编译 IR（boolProgram 应为 null）")

	# 开启 useIR 后做一次全量重建（与加载存档同路径），验证编译产物
	control.useIR = true
	control.updateBuildCircuit(bm.getAllBuilds())
	var prog: SWBoolProgram = control.boolProgram
	assert_not_null(prog, "useIR=true 时 updateBuildCircuit 应产出 boolProgram")
	if prog == null:
		return
	var n: int = prog.op_arr.size()
	assert_gt(n, 0, "IR 程序为空")

	# ── Fix-4B 问题1：OP_OUT 的 dst 是 slot 索引，不是指令索引 ──
	var out_slots: Array = []
	for i in range(n):
		if prog.op_arr[i] != SWBoolProgram.OP_OUT:
			continue
		var d: int = prog.dst_arr[i]
		assert_between(d, 0, prog.output_meta.size() - 1,
			"OP_OUT dst(%d) 应落在 output_meta 范围内" % d)
		assert_false(out_slots.has(d), "OP_OUT dst slot %d 重复（同 net 应去重）" % d)
		out_slots.append(d)
		assert_true(prog.output_meta[d].has("net"), "output_meta[%d] 缺少 net" % d)
	# slot 由 _alloc_slot 顺序分配，output_meta 长度不应超过 slot 总数；
	# 旧 bug（dst=指令索引）会让 meta/slots 膨胀到指令数量级
	assert_lte(prog.output_meta.size(), n,
		"output_meta 长度(%d)不应超过指令数(%d)，否则说明 dst 仍是指令索引" % [prog.output_meta.size(), n])
	assert_gt(out_slots.size(), 0, "存档中应至少有一条 OP_OUT")

	# ── Fix-4B 问题2：OP_OUT 的目标 net 必须是某建筑输出方向的 net ──
	for d in out_slots:
		var net: SWNet = prog.output_meta[d].net
		assert_not_null(net, "output_meta[%d].net 为 null" % d)
		if net == null:
			continue
		var found_output_pin := false
		for driver: Dictionary in net.getDrivers():
			var db: SWBuildItemDefine = driver["build"]
			if db == null:
				continue
			var comp: SWBuildCompoentCircuit = db.getCircuitCompoent()
			if comp != null and comp.portIsOutput(driver["pinDir"]):
				found_output_pin = true
				break
		assert_true(found_output_pin,
			"OP_OUT 目标 net 应由输出方向引脚驱动（旧 bug：NOT 门写回了输入 net）")

	# ── evaluate 冒烟：dst/a 全部落在 _slots 范围内，不应报错 ──
	prog.evaluate()

	# ── NOT 门专项：结果必须写回 rotation 方向的输出 net ──
	var not_checked: int = 0
	var out_nets: Dictionary = {}
	for d in out_slots:
		out_nets[prog.output_meta[d].net] = true
	for b: SWBuildItemDefine in bm.getAllBuilds():
		if b.buildDefine == null:
			continue
		if b.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.NOT_GATE:
			continue
		var comp: SWBuildCompoentCircuit = b.getCircuitCompoent()
		var out_net: SWNet = comp.pinNetMap.get(b.rotation, null)
		if out_net == null:
			continue
		assert_true(out_nets.has(out_net),
			"NOT 门 %s 的输出 net 未出现在 OP_OUT 目标中" % str(b.buildAxisPos))
		# 旧 bug 的直接表现：NOT 门把结果写回自己的输入 net。
		# 注意输入 net 可能合法地被上游其他门驱动，所以只检查该 NOT 自身是否是驱动者
		var in_net: SWNet = comp.pinNetMap.get(SwDefine.getAntiDir(b.rotation), null)
		if in_net != null and in_net != out_net and out_nets.has(in_net):
			var not_drives_own_input := false
			for driver: Dictionary in in_net.getDrivers():
				if driver["build"] == b:
					not_drives_own_input = true
					break
			assert_false(not_drives_own_input,
				"NOT 门 %s 自己的输入 net 被 OP_OUT 写回（dst net 方向错误）" % str(b.buildAxisPos))
		not_checked += 1
	gut.p("检查了 %d 个 NOT 门的 OP_OUT 输出方向" % not_checked)

	# ── LED 不应产生 OP_OUT（输入侧表达式无输出 net） ──
	var led_nets: Dictionary = {}
	for b: SWBuildItemDefine in bm.getAllBuilds():
		if b.buildDefine == null:
			continue
		if b.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.LED:
			continue
		var comp: SWBuildCompoentCircuit = b.getCircuitCompoent()
		for net in comp.pinNetMap.values():
			if net != null:
				led_nets[net] = b
	for net in led_nets:
		if out_nets.has(net):
			var led_build: SWBuildItemDefine = led_nets[net]
			var led_is_driver := false
			for driver: Dictionary in net.getDrivers():
				if driver["build"] == led_build:
					led_is_driver = true
					break
			assert_false(led_is_driver,
				"LED %s 无输出引脚，不应作为 OP_OUT 目标" % str(led_build.buildAxisPos))
