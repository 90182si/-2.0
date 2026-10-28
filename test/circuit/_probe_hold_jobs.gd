extends GutTest
# 复制/剪切准备与放置任务（主线程分帧）验证：
#   1) 复制：准备期间手持为空、放置与剪贴板操作被闸门挡住，准备完成后克隆才上屏
#   2) 剪切：源建筑立即删除，克隆照常准备
#   3) 放置：多次落笔合并成一条任务进度，任务未完成时仍可继续放置
#   4) 左下角进度条的显隐接口

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

func _def(def_name: String) -> SWBuildDefine:
	return load("res://res/" + def_name + ".tres") as SWBuildDefine

func _place(pos: Vector2i, def_name: String) -> SWBuildItemDefine:
	var build := SwDefine.SWBuildCreator(pos, _def(def_name), 0)
	assert_true(_sys().build_manager.addBuild(build), "添加建筑失败: " + def_name)
	return build

func _select(builds: Array) -> void:
	for b: SWBuildItemDefine in builds:
		_sys()._selected_builds[b] = true

# 等任务跑完（帧数上限内），返回是否在预算内完成
func _wait_idle(max_frames: int) -> bool:
	for i in max_frames:
		if not _sys().is_job_running():
			return true
		await get_tree().process_frame
	return not _sys().is_job_running()

# ---------------- 复制准备 ----------------
func test_copy_prepare_staged_then_reveals_hold() -> void:
	await harness.boot_game()
	var sys := _sys()
	var hold_sys := _hold_sys()
	var hold_view := harness.layer_manager.holdLayer as SWHoldLayer
	_place(Vector2i(0, 0), "开关")
	_place(Vector2i(128, 0), "电线A")
	_place(Vector2i(256, 0), "灯泡")
	_select(sys.build_manager.getAllBuilds())

	assert_false(sys.is_clipboard_busy())
	sys._do_copy()

	assert_true(sys.is_clipboard_busy(), "复制准备应立即进入忙碌态")
	assert_false(sys.can_place(), "准备期间禁止放置")
	assert_false(sys.can_edit_clipboard(), "准备期间禁止复制/剪切")
	assert_false(hold_view.sw_draw_manager.is_visible(), "准备完成前手持预览不可见")

	assert_true(await _wait_idle(300), "复制准备未在预算内完成")
	assert_false(sys.is_clipboard_busy())
	assert_true(sys.can_place())
	assert_true(sys.can_edit_clipboard())
	assert_false(hold_sys.is_hold_empty(), "准备完成后手持应有克隆")
	assert_eq(hold_sys._hold_builds.size(), 3, "克隆数量应与选中一致")

	var hold_data := hold_view.get_hold_draw_data()
	assert_not_null(hold_data, "准备完成后手持绘制数据应已安装")
	assert_eq(hold_data.mapDatas.size(), 3)
	assert_true(hold_view.is_hold_render_idle(), "手持区块应已全部构建完毕")
	assert_true(hold_view.sw_draw_manager.is_visible(), "构建完成后手持应可见")

	# 手持建筑完全不参与电路：克隆不建电路组件、不挂电路分组
	for b: SWBuildItemDefine in hold_sys._hold_builds:
		assert_true(b.is_preview, "手持克隆应标记为预览建筑")
		assert_null(b._circuitCompoent, "手持克隆不应创建电路组件")
		assert_null(b.circuit, "手持克隆不应挂到电路")

# ---------------- 剪切准备 ----------------
func test_cut_deletes_source_before_prepare() -> void:
	await harness.boot_game()
	var sys := _sys()
	var hold_sys := _hold_sys()
	_place(Vector2i(0, 0), "灯泡")
	_place(Vector2i(128, 0), "灯泡")
	_select(sys.build_manager.getAllBuilds())

	sys._do_cut()
	# 源建筑立即消失，克隆的准备在后面几帧里继续
	assert_null(sys.build_manager.getBuild(Vector2i(0, 0)), "剪切应立即删除源建筑")
	assert_null(sys.build_manager.getBuild(Vector2i(128, 0)))
	assert_true(sys.is_clipboard_busy())

	assert_true(await _wait_idle(300), "剪切准备未在预算内完成")
	assert_false(hold_sys.is_hold_empty(), "剪切完成后手持应有克隆")
	assert_eq(hold_sys._hold_builds.size(), 2)

# ---------------- 放置任务 ----------------
func test_place_jobs_aggregate_and_keep_placing() -> void:
	await harness.boot_game()
	var sys := _sys()
	var hold_sys := _hold_sys()
	# 一段可以整体复制的小电路：开关 + 电线 + 灯泡
	_place(Vector2i(128, 0), "开关")
	_place(Vector2i(256, 0), "电线A")
	_place(Vector2i(384, 0), "灯泡")
	sys.circuit_control.updateBuildCircuit(sys.build_manager.getAllBuilds())
	_select(sys.build_manager.getAllBuilds())
	sys._do_copy()
	assert_true(await _wait_idle(300), "复制准备未在预算内完成")

	var held: Array[SWBuildItemDefine] = hold_sys._hold_builds.duplicate()
	assert_eq(held.size(), 3)

	sys.on_hold_idle_builds(held, [Vector2i(256, 512)])
	assert_true(sys.is_job_running(), "放置任务应立即开始")
	assert_false(sys.can_edit_clipboard(), "放置未完成时禁止复制/剪切")
	assert_true(sys.can_place(), "放置未完成时仍可继续放置")

	# 任务跑到一半再落一笔：应合并进同一条任务进度
	sys.on_hold_idle_builds(held, [Vector2i(256, 1024)])
	assert_eq(sys._place_total, 6, "进度口径应按全部放置任务累计")
	assert_true(await _wait_idle(600), "放置任务未在预算内完成")

	var mgr: SWBuildManager = harness.build_layer.sw_build_manager
	for anchor: Vector2i in [Vector2i(256, 512), Vector2i(256, 1024)]:
		var switch_pos: Vector2i = anchor + Vector2i(-128, 0)
		var led_pos: Vector2i = anchor + Vector2i(128, 0)
		var sw = mgr.getBuild(switch_pos)
		var wire = mgr.getBuild(anchor)
		var led = mgr.getBuild(led_pos)
		assert_not_null(sw, "开关未落地: " + str(switch_pos))
		assert_not_null(wire, "电线未落地: " + str(anchor))
		assert_not_null(led, "灯泡未落地: " + str(led_pos))
		# 落地的必须是真建筑（不是预览克隆），且分阶段重建跑完后有电路分组
		assert_false(sw.is_preview if sw != null else true, "落地建筑不应是预览建筑")
		assert_not_null(sw.circuit if sw != null else null, "开关电路未重建: " + str(switch_pos))
		assert_not_null(led.circuit if led != null else null, "灯泡电路未重建: " + str(led_pos))
	assert_eq(sys._place_total, 0, "任务结束后进度应归零")
	assert_false(harness.layer_manager.hudLayer.is_job_progress_visible(), "任务结束后进度条应隐藏")

# ---------------- 放置中右键收手 ----------------
func test_right_click_clears_hold_during_place() -> void:
	await harness.boot_game()
	var sys := _sys()
	var hold_sys := _hold_sys()
	var hold_view := harness.layer_manager.holdLayer as SWHoldLayer
	_place(Vector2i(128, 0), "开关")
	_place(Vector2i(256, 0), "电线A")
	_place(Vector2i(384, 0), "灯泡")
	_select(sys.build_manager.getAllBuilds())
	sys._do_copy()
	assert_true(await _wait_idle(300), "复制准备未在预算内完成")

	var held: Array[SWBuildItemDefine] = hold_sys._hold_builds.duplicate()
	assert_eq(held.size(), 3)
	sys.on_hold_idle_builds(held, [Vector2i(256, 512)])
	assert_true(sys.is_job_running(), "放置任务应已开始")
	assert_true(sys.can_place(), "放置未完成时仍可继续放置")
	assert_false(hold_sys.is_hold_empty())

	# 放置没跑完也允许右键清空手持；已入队的放置任务不受影响
	hold_sys._on_right_pressed(hold_view)
	assert_true(hold_sys.is_hold_empty(), "放置未完成时右键应能清空手持")
	assert_true(sys.is_job_running(), "清空手持不应取消已入队的放置任务")
	assert_false(sys.can_erase(), "放置仍在进行时擦除仍被挡住")

	assert_true(await _wait_idle(600), "放置任务未在预算内完成")
	var mgr: SWBuildManager = harness.build_layer.sw_build_manager
	assert_not_null(mgr.getBuild(Vector2i(128, 512)), "清空手持后已入队的建筑仍应落地")
	assert_not_null(mgr.getBuild(Vector2i(256, 512)))
	assert_not_null(mgr.getBuild(Vector2i(384, 512)))
	var led = mgr.getBuild(Vector2i(384, 512))
	assert_not_null(led.circuit if led != null else null, "清空手持后电路重建仍应完成")
	assert_true(sys.can_erase(), "任务结束后擦除恢复")

# ---------------- 性能监视器悬停提示 ----------------
# 分阶段重建期间电线的 net 可能还没建出来，悬停提示不能因此报错
func test_monitor_tooltip_handles_missing_net() -> void:
	var mon: SWPerformanceMonitor = SWPerformanceMonitor.new()
	var wire := SwDefine.SWBuildCreator(Vector2i(0, 0), _def("电线A"), 0)
	assert_null((wire.getCircuitCompoent() as SWBuildCompoentCircuitWire).net)
	assert_true(mon._format_build_info(wire).contains("WireGroup"), "电线提示应带 WireGroup 行")
	var bridge := SwDefine.SWBuildCreator(Vector2i(0, 0), _def("电线桥梁"), 0)
	var bridge_text := mon._format_build_info(bridge)
	assert_true(bridge_text.contains("VerticalWireGroup"), "桥梁提示应带纵向线组")
	assert_true(bridge_text.contains("HorizontalWireGroup"), "桥梁提示应带横向线组")
	mon.free()

# ---------------- 手持阴影与 LOD ----------------
func _shadow_all_visible(hold_view: SWHoldLayer) -> bool:
	var dm = hold_view.sw_draw_manager_shadow
	var arr: Array = dm.get_loaded_chunk_positions()
	if arr.is_empty():
		return false
	for cp: Vector2i in arr:
		if not dm._chunkInstance[cp].mesh_instance.visible:
			return false
	return true

func test_hold_shadow_hidden_in_lod() -> void:
	await harness.boot_game()
	var hold_sys := _hold_sys()
	var hold_view := harness.layer_manager.holdLayer as SWHoldLayer
	hold_sys.set_hold_tool(_def("灯泡"))
	await wait_process_frames(5)
	assert_gt(hold_view.sw_draw_manager_shadow.get_loaded_chunk_positions().size(), 0,
		"手持阴影区块应已构建")

	SwAtlas.set_lod(0)
	assert_true(_shadow_all_visible(hold_view), "LOD0 应显示手持阴影")
	SwAtlas.set_lod(1)
	assert_false(_shadow_all_visible(hold_view), "LOD1 不应显示手持阴影")
	SwAtlas.set_lod(2)
	assert_false(_shadow_all_visible(hold_view), "LOD2 不应显示手持阴影")
	SwAtlas.set_lod(0)
	assert_true(_shadow_all_visible(hold_view), "回到 LOD0 后手持阴影应恢复")

# ---------------- 进度条 ----------------
func test_hud_job_progress_panel_visibility() -> void:
	await harness.boot_game()
	var hud: SWHudLayer = harness.layer_manager.hudLayer
	assert_not_null(hud)
	assert_false(hud.is_job_progress_visible(), "初始应不可见")
	hud.show_job_progress("准备复制 1/2", 0.5)
	assert_true(hud.is_job_progress_visible())
	hud.show_job_progress("准备复制 2/2", 1.0)
	hud.hide_job_progress()
	assert_false(hud.is_job_progress_visible())
