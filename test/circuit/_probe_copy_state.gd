extends GutTest
# 复制/剪切要带走建筑自身的电路状态：
#   1) 按下的开关复制出来仍然按下（贴图也立刻是按下帧）
#   2) 寄存器的锁存值与时钟相位一起复制，放置后不会多锁存一次
#   3) 剪切（源建筑先删）同样保留状态

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

# ---------------- 工具 ----------------
func _sys() -> SWBuildLayerSystem:
	return harness.build_layer.layer_system as SWBuildLayerSystem

func _hold_sys() -> SWHoldLayerSystem:
	return harness.layer_manager.holdSystem

func _mgr() -> SWBuildManager:
	return harness.build_layer.sw_build_manager

func _def(def_name: String) -> SWBuildDefine:
	return load("res://res/" + def_name + ".tres") as SWBuildDefine

func _place(pos: Vector2i, def_name: String) -> SWBuildItemDefine:
	var build := SwDefine.SWBuildCreator(pos, _def(def_name), 0)
	assert_true(_mgr().addBuild(build), "添加建筑失败: " + def_name)
	return build

func _select_all() -> void:
	_sys()._selected_builds.clear()
	for b: SWBuildItemDefine in _mgr().getAllBuilds():
		_sys()._selected_builds[b] = true

func _wait_idle(max_frames: int) -> bool:
	for i in max_frames:
		if not _sys().is_job_running():
			return true
		await get_tree().process_frame
	return not _sys().is_job_running()

# 一次复制 + 在 anchor 落一笔，返回放置后的手持克隆数组
func _copy_and_paste(anchor: Vector2i) -> Array:
	_select_all()
	_sys()._do_copy()
	assert_true(await _wait_idle(300), "复制准备未在预算内完成")
	var held: Array[SWBuildItemDefine] = _hold_sys()._hold_builds.duplicate()
	assert_gt(held.size(), 0, "手持应有克隆")
	_sys().on_hold_idle_builds(held, [anchor])
	assert_true(await _wait_idle(600), "放置任务未在预算内完成")
	return held

# ---------------- 开关 ----------------
func test_copy_keeps_pressed_switch() -> void:
	await harness.boot_game()
	var sw := _place(Vector2i(128, 0), "开关") as SWBuildButton
	assert_not_null(sw, "开关创建失败")
	sw.onPressed(true)
	assert_true(sw.pressed, "源开关应先按下")

	var held := await _copy_and_paste(Vector2i(128, 512))
	#手持克隆只是预览建筑：不建电路组件，但贴图要显示按下状态
	var clone := held[0] as SWBuildItemDefine
	assert_true(clone.is_preview, "手持应为预览克隆")
	assert_null(clone._circuitCompoent, "手持克隆不应创建电路组件")
	assert_eq(clone.getRenderableCompoent().drawRect, clone.buildDefine.atlasTextureOn.region,
		"手持中的开关也应显示按下帧")

	var placed := _mgr().getBuild(Vector2i(128, 512)) as SWBuildButton
	assert_not_null(placed, "开关未落地")
	assert_false(placed.is_preview, "落地建筑不应是预览克隆")
	assert_true(placed.pressed, "复制出来的开关应保持按下")
	assert_eq(placed.getRenderableCompoent().drawRect, placed.buildDefine.atlasTextureOn.region,
		"落地后的贴图应直接是按下帧")

# ---------------- 寄存器 ----------------
func test_copy_keeps_register_latch() -> void:
	await harness.boot_game()
	var reg := _place(Vector2i(128, 0), "1bit寄存器")
	var cir := reg.getCircuitCompoent() as SWBuildCompoentCircuitRegister
	assert_not_null(cir, "寄存器组件缺失")
	cir.qState = SwDefine.CircuitSignal.HIGH
	cir.curClk = SwDefine.CircuitSignal.LOW
	cir.lastClk = SwDefine.CircuitSignal.LOW

	await _copy_and_paste(Vector2i(128, 512))

	var placed := _mgr().getBuild(Vector2i(128, 512))
	assert_not_null(placed, "寄存器未落地")
	var placed_cir := placed.getCircuitCompoent() as SWBuildCompoentCircuitRegister
	assert_not_null(placed_cir, "落地寄存器组件缺失")
	assert_eq(placed_cir.qState, SwDefine.CircuitSignal.HIGH, "寄存器锁存值应随复制保留")
	assert_eq(placed.getRenderableCompoent().drawRect, placed.buildDefine.atlasTextureOn.region,
		"锁存为高的寄存器落地后应显示点亮帧")
	#落地后会按实际时钟 net 重新对齐相位（这里没接时钟，退回 NONE 是正确结果），
	#恢复契约本身单独验：存档里的 clk 必须同时写进 curClk 与 lastClk
	var fresh := SwDefine.SWBuildCreator(Vector2i(0, 1024), _def("1bit寄存器"), 0)
	fresh.load_state({"q": int(SwDefine.CircuitSignal.HIGH), "clk": int(SwDefine.CircuitSignal.HIGH)})
	var fresh_cir := fresh.getCircuitCompoent() as SWBuildCompoentCircuitRegister
	assert_eq(fresh_cir.qState, SwDefine.CircuitSignal.HIGH)
	assert_eq(fresh_cir.lastClk, SwDefine.CircuitSignal.HIGH, "恢复后 lastClk 与 curClk 同相位，不会多锁存一次")

# ---------------- 剪切 ----------------
func test_cut_keeps_pressed_switch() -> void:
	await harness.boot_game()
	var sw := _place(Vector2i(128, 0), "开关") as SWBuildButton
	assert_not_null(sw, "开关创建失败")
	sw.onPressed(true)

	_select_all()
	_sys()._do_cut()
	assert_null(_mgr().getBuild(Vector2i(128, 0)), "剪切应立即删除源开关")
	assert_true(await _wait_idle(300), "剪切准备未在预算内完成")

	var held: Array[SWBuildItemDefine] = _hold_sys()._hold_builds.duplicate()
	assert_eq(held.size(), 1)
	_sys().on_hold_idle_builds(held, [Vector2i(128, 512)])
	assert_true(await _wait_idle(600), "放置任务未在预算内完成")

	var placed := _mgr().getBuild(Vector2i(128, 512)) as SWBuildButton
	assert_not_null(placed, "开关未落地")
	assert_true(placed.pressed, "剪切后再放置的开关应保持按下")
