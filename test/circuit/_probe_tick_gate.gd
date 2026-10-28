extends GutTest
# 电路拍节流验证：
#   1) 同一渲染帧内只消耗一个节拍（物理子步补跑不再叠加传播）
#   2) 不足 1/30 秒不传播
#   3) LOD2 整屏冻结时求值照跑，但不再登记补丁

const HARNESS_SCRIPT := preload("res://test/circuit/circuit_test_harness.gd")

var harness = null

func before_each() -> void:
	harness = HARNESS_SCRIPT.new()
	add_child_autofree(harness)

func after_each() -> void:
	if harness != null:
		harness.shutdown_game()
		harness = null

func _sys() -> SWBuildLayerSystem:
	return harness.build_layer.layer_system

func _boot() -> void:
	await harness.boot_game()
	var data: Dictionary = await harness.load_save("2x计数器")
	assert_false(data.is_empty(), "存档加载失败")
	harness.force_load_all_chunks()
	harness.flush_draw_queue()
	SwAtlas.set_lod(0)

func test_tick_gate() -> void:
	await _boot()
	var sys := _sys()
	var clock := sys.clockBuildArr.keys()[0] as SWBuildClockSiggen
	var sig0: int = int(clock.curSig)

	#同一渲染帧内：帧门先挡住，不消耗节拍
	sys._last_tick_frame = Engine.get_process_frames()
	sys._last_clock_usec = Time.get_ticks_usec() - 100000
	var stamp: int = sys._last_clock_usec
	sys.tick(0.05, 1)
	assert_eq(sys._last_clock_usec, stamp, "同一帧内不应有第二拍")
	assert_eq(int(clock.curSig), sig0, "同一帧内时钟不应翻转")

	#下一帧但不足 1/30 秒：时间门挡住
	sys._last_tick_frame = -1
	sys._last_clock_usec = Time.get_ticks_usec()
	sys.tick(0.05, 1)
	assert_eq(int(clock.curSig), sig0, "不足节拍时间不应传播")

	#越过节拍：正常传播
	sys._last_tick_frame = -1
	sys._last_clock_usec = Time.get_ticks_usec() - 100000
	sys.tick(0.05, 1)
	assert_ne(int(clock.curSig), sig0, "越过节拍应翻转时钟并传播")

func test_lod2_skips_patch_but_keeps_eval() -> void:
	await _boot()
	var sys := _sys()
	var dm = harness.build_layer.sw_draw_manager
	var cc: SWCircuitControl = harness.build_layer.sw_circuit_control
	var clock := sys.clockBuildArr.keys()[0] as SWBuildClockSiggen

	SwAtlas.set_lod(2)
	assert_true(SwAtlas.is_frame_updates_frozen())
	dm._flush_patches(100000000)
	var epoch0: int = cc._curEpoch
	var sig0: int = int(clock.curSig)
	sys._last_tick_frame = -1
	sys._last_clock_usec = Time.get_ticks_usec() - 100000
	sys.tick(0.05, 1)

	assert_ne(int(clock.curSig), sig0, "LOD2 下时钟仍应推进")
	assert_ne(cc._curEpoch, epoch0, "LOD2 下电路求值仍应推进")
	assert_true(dm._patch_queue.is_empty(), "LOD2 冻结档不应登记信号补丁")
	SwAtlas.set_lod(0)
