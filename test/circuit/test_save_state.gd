extends GutTest
# 存档必须带上元件自持状态：开关按下、时钟相位、寄存器锁存值。
# 改造前只存 signal_state（显示快照），加载后开关的 pressed 仍是 false、
# 寄存器 qState 仍是 LOW，信号源读回低电平 → 整台计数器回到起点，
# 存档里拨亮的开关一加载就全灭。这里走游戏真实入口（SWSaveManager.save_builds +
# SWBuildLayer.load_save_data）量「存前 / 载后」四份状态逐位一致。

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const SAVE_COUNTER := "2x计数器"
const TEMP_SAVE := "__test_save_state"
const TICK_FRAMES := 40

func test_state_survives_save_and_load() -> void:
	var harness = HARNESS_SCRIPT.new()
	add_child(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save(SAVE_COUNTER)
	if data.is_empty():
		pending("存档不存在，跳过: " + SAVE_COUNTER)
		await _dispose(harness)
		return
	# 先让计数器跑起来：静止状态下「状态没存」和「状态存对了」看不出差别
	_turn_on_switches(harness)
	for f in range(TICK_FRAMES):
		await get_tree().process_frame
	# 冻结 _process 的时钟循环：它每 2 帧就翻转一次 curSig，
	# 存前/载后的比对若夹着真实打拍，qState 本来就会前进，断言无从判定
	harness.build_layer.set_process(false)
	# 把快照取在不动点上：若保存那一刻正好处于「时钟已抬高、上升沿还没锁存」的半拍，
	# 加载末尾的 updateBuildCircuit 会先把这一拍锁存掉，比对就凭空差一位。
	# 这里先跑一次与加载路径同款的整段重算，让存前状态已经是结算后的值
	harness.build_layer.sw_circuit_control.updateBuildCircuit(
		harness.build_layer.sw_build_manager.getAllBuilds())
	var before := _state_of(harness)
	assert_gt(before.qstate.length(), 0, "存档里没有寄存器，用例失效")
	assert_true(before.switch.contains("1"), "开关没能拨亮，用例失效")

	# headless 下 viewport.get_texture() 为 null，截图会报 engine error；
	# 缩略图与存档数据无关，这里传 null 跳过 _capture_thumbnail
	var ok := SWSaveManager.save_builds(TEMP_SAVE,
		harness.build_layer.sw_build_manager.getAllBuilds(), null, {})
	assert_true(ok, "写存档失败")
	var reloaded: Dictionary = await harness.load_save(TEMP_SAVE)
	assert_false(reloaded.is_empty(), "刚写的存档读不回来")

	var after := _state_of(harness)
	assert_eq(after.switch, before.switch, "开关按下状态没恢复（pressed）")
	assert_eq(after.clock, before.clock, "时钟相位没恢复（curSig）")
	assert_eq(after.qstate, before.qstate, "寄存器锁存值没恢复（qState）")
	assert_eq(after.led, before.led, "载后显示电平与存档前不一致")
	# 恢复的不只是显示：继续沿时钟往下数，才说明状态机接得上
	harness.build_layer.set_process(true)
	for f in range(TICK_FRAMES):
		await get_tree().process_frame
	var moving := _state_of(harness)
	assert_ne(moving.qstate, after.qstate, "载后计数器不再走动，说明沿检测历史断了")
	await _dispose(harness)
	SWSaveManager.delete_save(TEMP_SAVE)
	assert_false(SWSaveManager.save_exists(TEMP_SAVE), "临时存档没清掉")

## 四份状态串：开关 pressed / 时钟 curSig / 寄存器 qState / LED 显示电平
## 一律按建筑 id 排序——加载后 getAllBuilds 的遍历顺序与存前不同，
## 不归一就没法逐位比对
func _state_of(harness) -> Dictionary:
	var builds: Array = harness.build_layer.sw_build_manager.getAllBuilds()
	builds.sort_custom(func(a, c): return a.id < c.id)
	var sw := ""
	var clk := ""
	var q := ""
	var led := ""
	for b: SWBuildItemDefine in builds:
		if b.buildDefine == null:
			continue
		var t: int = b.buildDefine.circuit_component_type
		if b is SWBuildClockSiggen:
			clk += "1" if (b as SWBuildClockSiggen).curSig == SwDefine.CircuitSignal.HIGH else "0"
		elif t == SwDefine.CircuitComponentType.SWITCH or t == SwDefine.CircuitComponentType.BUTTON:
			sw += "1" if (b as SWBuildButton).pressed else "0"
		elif t == SwDefine.CircuitComponentType.ONE_BIT_REGISTER:
			var comp := b.getCircuitCompoent() as SWBuildCompoentCircuitRegister
			q += "1" if comp != null and comp.qState == SwDefine.CircuitSignal.HIGH else "0"
		elif t == SwDefine.CircuitComponentType.LED:
			led += "1" if b.getDisplaySignal() == SwDefine.CircuitSignal.HIGH else "0"
	return {"switch": sw, "clock": clk, "qstate": q, "led": led}

func _turn_on_switches(harness) -> void:
	for b: SWBuildItemDefine in harness.build_layer.sw_build_manager.getAllBuilds():
		if b.buildDefine != null and b.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			harness.set_switch(b.buildAxisPos, true)

func _dispose(harness) -> void:
	harness.shutdown_game()
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(harness):
		remove_child(harness)
		harness.free()
