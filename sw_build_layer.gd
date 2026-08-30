class_name SWBuildLayer extends SWLayer

var sw_build_manager:SWBuildManager = null
#var sw_circuit_manager:SWCircuitManager = null
#var sw_circuit_analyzer:SWCircuitAnalyzer = null
var sw_circuit_control:SWCircuitControl = null
var holdLayerRef:SWHoldLayer = null
@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_build_manager = SWBuildManager.new()
	sw_draw_manager.setBuildManager(sw_build_manager)
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.ByContent)
	sw_draw_manager.useName = "Content"

	sw_circuit_control = SWCircuitControl.new()
	#sw_circuit_manager = SWCircuitManager.new()
	#sw_circuit_manager.setup(sw_build_manager)
	#add_child(sw_circuit_manager)
	# 断开旧电路管理器的 build_changed 连接，改用新的卡诺图分析器
	#if sw_build_manager.build_changed.is_connected(sw_circuit_manager._on_build_changed):
		#sw_build_manager.build_changed.disconnect(sw_circuit_manager._on_build_changed)
#
	#sw_circuit_analyzer = SWCircuitAnalyzer.new()
	#sw_circuit_analyzer.setup(sw_build_manager)
	#sw_circuit_analyzer.signal_changed.connect(_on_circuit_signal_changed)
	add_child(sw_circuit_control)
	sw_circuit_control.setBuildManager(sw_build_manager)
	
	#var build:SWBuildItemDefine = SWDefine.SWBuildCreator(Vector2i(0,0),load("res://res/按钮.tres") as SWBuildDefine)
	#var build2:SWBuildItemDefine = SWDefine.SWBuildCreator(Vector2i(0,0),load("res://res/开关.tres") as SWBuildDefine)
	#var build3:SWBuildItemDefine = SWDefine.SWBuildCreator(Vector2i(0,0),load("res://res/灯泡.tres") as SWBuildDefine)
	#var chunkPos = Vector2i(-2048,-2048)
	#sw_circuit_analyzer.begin_batch()
	#for x in range(0,128*16,128):
		#for y in range(0,128*16,128):
			#holdIdleBuilds([build],[Vector2i(x,y)+chunkPos])
			#holdIdleBuilds([build2],[Vector2i(x,y)])
			#holdIdleBuilds([build3],[Vector2i(x,y)-chunkPos])
	#sw_circuit_analyzer.end_batch()

	print("建筑创建完成，准备性能测试...")
	call_deferred("_run_initial_performance_test")

func _on_circuit_signal_changed() -> void:
	var all_builds = sw_build_manager.getAllBuilds()
	var notifyChunkPosArr = getNotifyChunkPosArr(all_builds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)

func _on_drag_started() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	pass

func _on_drag_ended() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	pass

func clear_all_builds() -> void:
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	sw_build_manager.clearAllBuilds()
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	sw_draw_manager.updataAllChunks()

func load_save_data(data: Dictionary) -> void:
	clear_all_builds()
	var builds_arr = data.get("builds", [])
	if not builds_arr is Array:
		return
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	for b in builds_arr:
		var pos_dict = b.get("pos", {})
		var def_name = b.get("def", "")
		var rot = b.get("rot", 0)
		var comp_type = b.get("comp_type", 0)
		var circuit_on = b.get("circuit_on", false)
		var signal_state = b.get("signal_state", 0)
		var tunnel_pair_id = b.get("tunnel_pair_id", -1)
		var in_loop = b.get("in_loop", false)
		var pos = Vector2i(pos_dict.get("x", 0), pos_dict.get("y", 0))
		var def_path = "res://res/" + def_name + ".tres"
		var build_def = load(def_path) as SWBuildDefine
		if not build_def:
			continue
		var build = SWDefine.SWBuildCreator(pos, build_def, rot)
		build.circuit_on = circuit_on
		build.signal_state = signal_state
		build.tunnel_pair_id = tunnel_pair_id
		build.in_loop = in_loop
		sw_build_manager.addBuild(build)
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	# 加载卡诺图数据（用于后续独立电路单元提取）
	var kmap_data = data.get("karnaugh_map", {})
	#if sw_circuit_analyzer and kmap_data is Dictionary and not kmap_data.is_empty():
		#sw_circuit_analyzer.load_karnaugh_map_data(kmap_data)
	sw_draw_manager.updataAllChunks()

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	pass

func getNotifyChunkPosArr(builds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		var chunkPos = SWCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

func holdIdleBuilds(builds:Array[SWBuildItemDefine],poss:Array[Vector2i]) -> void:
	var successBuilds:Array[SWBuildItemDefine] = []
	for pos in poss:
		var gridPos = SWCommon.GetGridPos(pos)
		for build in builds:
			#var newBuild = SWBuildItemDefine.new(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			var newBuild = SWDefine.SWBuildCreator(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			var ok := sw_build_manager.addBuild(newBuild)
			if ok:
				successBuilds.append(newBuild)

	if successBuilds.size() == 0:
		return

	var notifyChunkPosArr = getNotifyChunkPosArr(successBuilds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	if sw_circuit_control:
		sw_circuit_control.updateBuildCircuit(successBuilds)
		sw_draw_manager.updataChunks(notifyChunkPosArr)

func holdRemoveBuilds(poss:Array[Vector2i]) -> void:
	if selectedBuilds.size() != 0:
		var notifyChunkPosArr = getNotifyChunkPosArr(selectedBuilds.keys())
		for build in selectedBuilds:
			if not build:
				continue
			sw_build_manager.setBuildState(build,SWDefine.BuildState.IDLE)
		sw_draw_manager.updataChunks(notifyChunkPosArr)
		selectedBuilds.clear()
		return
	var builds := sw_build_manager.getBuilds(poss)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	if sw_circuit_control:
		sw_build_manager.setBuildsState(builds,SWDefine.BuildState.TO_BE_REMOVED)
		sw_circuit_control.updateBuildCircuit(builds)
		#sw_draw_manager.updataChunks(notifyChunkPosArr)
	for build in builds:
		if selectedBuilds.has(build):
			selectedBuilds.erase(build)
	sw_build_manager.delBuilds(builds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)

var selectedBuilds:Dictionary[SWBuildItemDefine,bool] = {}

signal cut_builds()
signal copy_builds()

func setSelectedRect(rect:Rect2) -> void:
	var builds := sw_build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		selectedBuilds[build] = true
		sw_build_manager.setBuildState(build,SWDefine.BuildState.SELECTED)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass

func clearSelectedByRect(rect:Rect2) -> void:
	var builds := sw_build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		if selectedBuilds.has(build):
			selectedBuilds.erase(build)
			sw_build_manager.setBuildState(build,SWDefine.BuildState.IDLE)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass

func _getSelectedBuildCenter() -> Vector2i:
	if selectedBuilds.size() == 0:
		return Vector2i.ZERO
	var minPos := Vector2i(999999, 999999)
	var maxPos := Vector2i(-999999, -999999)
	for build in selectedBuilds:
		var pos = build.buildAxisPos
		minPos.x = min(minPos.x, pos.x)
		minPos.y = min(minPos.y, pos.y)
		maxPos.x = max(maxPos.x, pos.x)
		maxPos.y = max(maxPos.y, pos.y)
	var center = (minPos + maxPos) / 2
	var gs = Vector2(SWDefine.GRID_SIZE)
	return Vector2i((Vector2(center) / gs).floor() * gs)

func _do_cut() -> void:
	if selectedBuilds.size() == 0:
		return
	if not holdLayerRef:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	holdLayerRef.setHeldBuilds(builds, center)
	var poss:Array[Vector2i] = []
	for build in builds:
		poss.append(build.buildAxisPos)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	sw_build_manager.delBuilds(builds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	selectedBuilds.clear()
	#if sw_circuit_analyzer and not sw_circuit_analyzer.is_in_batch():
		#sw_circuit_analyzer.analyze()

func _do_delete_selected() -> void:
	if selectedBuilds.size() == 0:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	selectedBuilds.clear()
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.begin_batch()
	sw_build_manager.delBuilds(builds)
	#if sw_circuit_analyzer:
		#sw_circuit_analyzer.end_batch()
	sw_draw_manager.updataChunks(notifyChunkPosArr)

func _do_copy() -> void:
	if selectedBuilds.size() == 0:
		return
	if not holdLayerRef:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in selectedBuilds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	holdLayerRef.setHeldBuilds(builds, center)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		sw_build_manager.setBuildState(build,SWDefine.BuildState.IDLE)
	selectedBuilds.clear()
	sw_draw_manager.updataChunks(notifyChunkPosArr)

var _pressed_button_pos:Vector2i = Vector2i(-9999, -9999)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed():
		if event.keycode == KEY_DELETE:
			_do_delete_selected()
			get_viewport().set_input_as_handled()
			return
		if event.ctrl_pressed and selectedBuilds.size() > 0:
			if event.keycode == KEY_X:
				cut_builds.emit()
				get_viewport().set_input_as_handled()
				return
			elif event.keycode == KEY_C:
				copy_builds.emit()
				get_viewport().set_input_as_handled()
				return

	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_LEFT:
				var viewport := get_viewport()
				var mouse_pos := viewport.get_mouse_position()
				var world_pos = SWCommon.GetGlobalPosByViewPos(mouse_pos, viewport)
				var grid_pos:Vector2i = SWCommon.GetGridPos(Vector2i(world_pos))
				var build = sw_build_manager.getBuild(grid_pos)
				if build and (build.comp_type == SWDefine.CircuitComponentType.BUTTON or build.comp_type == SWDefine.CircuitComponentType.SWITCH):
					if build.comp_type == SWDefine.CircuitComponentType.BUTTON:
						build.onPressed(true)
					elif build.comp_type == SWDefine.CircuitComponentType.SWITCH:
						build.onPressed(!build.pressed)
					var newBuilds = sw_circuit_control.buildSignalChanged(build)
					newBuilds.append(build)
					#var notifyChunkPosArr = getNotifyChunkPosArr([build])
					var notifyChunkPosArr = getNotifyChunkPosArr(newBuilds)
					sw_draw_manager.updataChunks(notifyChunkPosArr)
					if build.comp_type == SWDefine.CircuitComponentType.BUTTON:
						_pressed_button_pos = grid_pos
					get_viewport().set_input_as_handled()
					return
		elif event.is_released():
			if event.button_index == MOUSE_BUTTON_LEFT:
				if _pressed_button_pos != Vector2i(-9999, -9999):
					var grid_pos:Vector2i = SWCommon.GetGridPos(Vector2i(_pressed_button_pos))
					var build = sw_build_manager.getBuild(grid_pos)
					if build and (build.comp_type == SWDefine.CircuitComponentType.BUTTON or build.comp_type == SWDefine.CircuitComponentType.SWITCH):
						if build.comp_type == SWDefine.CircuitComponentType.BUTTON:
							build.onPressed(false)
						elif build.comp_type == SWDefine.CircuitComponentType.SWITCH:
							pass
						var newBuilds = sw_circuit_control.buildSignalChanged(build)
						newBuilds.append(build)
						var notifyChunkPosArr = getNotifyChunkPosArr(newBuilds)
						sw_draw_manager.updataChunks(notifyChunkPosArr)
					_pressed_button_pos = Vector2i(-9999, -9999)

	if event.is_action_pressed("TEST_PERFORMANCE"):
		print("开始性能测试...")
		var test_regions = [
			Rect2i(Vector2i(0, 0), Vector2i(512, 512)),
			Rect2i(Vector2i(0, 0), Vector2i(1024, 1024)),
			Rect2i(Vector2i(-512, -512), Vector2i(2048, 2048))
		]
		for region in test_regions:
			sw_build_manager.test_getBuildsByRect_performance(region)
			await get_tree().create_timer(0.5).timeout

func _run_initial_performance_test():
	await get_tree().create_timer(1.0).timeout
	print("=== 初始化性能测试 ===")
	var test_region = Rect2i(Vector2i(0, 0), Vector2i(512, 512))
	sw_build_manager.test_getBuildsByRect_performance(test_region)
