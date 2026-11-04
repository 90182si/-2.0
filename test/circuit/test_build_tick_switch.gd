extends GutTest
# 性能面板「电路时钟 tick」开关契约（控制 SWBuildLayerSystem.tick 是否执行）：
#   1. tick_enabled = false 时 tick 直接返回：时钟电平原地冻结（不翻不锁不求值不刷显示）；
#   2. 重新打开后下一帧就恢复翻转；
#   3. 面板勾选框走真实信号直接落到 system.tick_enabled；
#   4. 面板拿不到系统（比 LayerManager 先 ready）时，勾选意图先挂起等系统就绪。
# 跑法：godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/circuit -gprefix test_build_tick_switch -gexit

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")
const MONITOR_SCENE := preload("res://performance/sw_performance_monitor.tscn")

# 起游戏 + 加载带时钟的存档，并等分帧放置收尾（放置期间 tick 是被挡掉的）
func _boot_counting() -> Array:
	var harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)
	await harness.boot_game()
	var data: Dictionary = await harness.load_save("计数器2")
	assert_false(data.is_empty(), "计数器2 存档要能加载")
	var sys: SWBuildLayerSystem = harness.layer_manager.buildSystem
	assert_not_null(sys, "建筑层系统要建起来")
	var guard := 0
	while guard < 300 and sys._place_running:
		guard += 1
		await get_tree().process_frame
	return [harness, sys]

# 存档里第一个时钟元件（tick 每拍调 onPressed(true)，电平必翻转）
func _first_clock(sys: SWBuildLayerSystem) -> SWBuildClockSiggen:
	for b in sys.clockBuildArr.keys():
		var clk := b as SWBuildClockSiggen
		if clk != null:
			return clk
	return null

# 1) 关掉 tick：时钟冻住；打开：下一帧就翻
func test_tick_switch_freezes_clock() -> void:
	var r = await _boot_counting()
	var sys: SWBuildLayerSystem = r[1]
	var clk := _first_clock(sys)
	assert_not_null(clk, "存档里要有能观察的时钟")
	assert_true(sys.tick_enabled, "默认 tick 是开的")

	# 先确认时钟本来真的在跳（避免后面「不动」是因为它压根没跑）
	var before = clk.curSig
	var moved := false
	for i in 6:
		await get_tree().process_frame
		if clk.curSig != before:
			moved = true
			break
	assert_true(moved, "开着 tick 时时钟应该在翻转")

	sys.tick_enabled = false
	var frozen = clk.curSig
	for i in 8:
		await get_tree().process_frame
		assert_eq(clk.curSig, frozen, "关掉 tick 后第 %d 帧时钟不该翻转" % i)

	sys.tick_enabled = true
	# 刚恢复时可能还赶不上同一帧的系统 tick，给几帧观察窗口
	var resumed := false
	for i in 6:
		await get_tree().process_frame
		if clk.curSig != frozen:
			resumed = true
			break
	assert_true(resumed, "重新打开 tick 后时钟恢复翻转")

# 2) 面板勾选框：真实信号链路直接落到 system
func test_panel_checkbox_controls_system_tick() -> void:
	var r = await _boot_counting()
	var harness = r[0]
	var sys: SWBuildLayerSystem = r[1]
	var mon = MONITOR_SCENE.instantiate()
	# 挂到游戏根下，面板才能按相对路径找到 SWLayerManager
	harness.scene.add_child(mon)
	await get_tree().process_frame
	assert_not_null(mon._tick_check, "面板要生成「电路时钟 tick」勾选框")
	assert_true(mon._tick_check.button_pressed, "默认勾上（tick 在跑）")
	assert_true(sys.tick_enabled, "按钮初值要与 system 实际状态一致")

	mon._tick_check.button_pressed = false
	assert_false(sys.tick_enabled, "取消勾选要直接停掉 system 的 tick")
	assert_eq(mon._tick_pending, -1, "系统已就绪时不该留待落地意图")

	mon._tick_check.button_pressed = true
	assert_true(sys.tick_enabled, "重新勾上要恢复 tick")
	mon.queue_free()

# 3) 拿不到系统时先挂起意图（面板可能比 SWLayerManager 先 ready）
func test_panel_defers_when_system_missing() -> void:
	var mon = MONITOR_SCENE.instantiate()
	add_child_autofree(mon)
	await get_tree().process_frame
	assert_not_null(mon._tick_check, "面板要生成勾选框")
	assert_null(mon._get_build_system(), "这个位置拿不到建筑层系统")
	mon._tick_check.button_pressed = false
	assert_eq(mon._tick_pending, 0, "意图要挂起等系统就绪，而不是丢掉")
