class_name SWBuildLayerSystem extends SWLayerSystem

var build_manager:SWBuildManager = null
var circuit_control:SWCircuitControl = null

#手持系统引用
var _hold_system:SWHoldLayerSystem = null
#选中的建筑物数组
var _selected_builds:Dictionary[SWBuildItemDefine,bool] = {}
#按住右键擦除期间暂存的被擦除建筑物，右键释放时统一更新电路
var _pendingRemovedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#按住左键放置期间暂存的新放置建筑物，左键释放时统一更新电路
var _pendingPlacedBuilds:Dictionary[SWBuildItemDefine,bool] = {}
#鼠标按下的位置
var _pressed_button_pos:Vector2i = Vector2i(-9999, -9999)

func _init() -> void:
	system_name = &"core.layer.build"
	run_order = SwDefine.ORDER_LAYER_BUILD
	build_manager = SWBuildManager.new()
	circuit_control = SWCircuitControl.new()
	circuit_control.setBuildManager(build_manager)

func _get_view() -> SWBuildLayer:
	return view as SWBuildLayer

func attach_view(v:SWLayer) -> void:
	super.attach_view(v)
	var build_layer := v as SWBuildLayer
	if build_layer != null:
		build_layer.attach_build_manager(build_manager)
		
#region 实时操作地图（放置、删除、框选）
#tag buildLayer放置元件
func on_hold_idle_builds(builds:Array[SWBuildItemDefine],positions:Array) -> void:
	var v := _get_view()
	if v == null:
		return
	var success:Array[SWBuildItemDefine] = []
	for pos in positions:
		var gridPos = SwCommon.GetGridPos(pos)
		for build in builds:
			var newBuild = SwDefine.SWBuildCreator(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			if build_manager.addBuild(newBuild):
				success.append(newBuild)
	if success.is_empty():
		return
	v.refresh_builds(success)
	for b in success:
		_pendingPlacedBuilds[b] = true
		
#tag buildLayer删除元件
func on_hold_remove_builds(positions:Array[Vector2i]) -> void:
	var v := _get_view()
	if v == null:
		return
	var grid_positions:Array[Vector2i] = []
	grid_positions.assign(positions)
	if _selected_builds.size() != 0:
		var notifyChunkPosArr = getNotifyChunkPosArr(_selected_builds.keys())
		for build in _selected_builds:
			if not build:
				continue
			build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
		_selected_builds.clear()
		return
	var builds := build_manager.getBuilds(positions)
	if builds.is_empty():
		return
	#按住右键期间只做视觉删除并记账，电路更新延迟到右键释放时统一执行
	build_manager.setBuildsState(builds,SwDefine.BuildState.TO_BE_REMOVED)
	for build in builds:
		if _selected_builds.has(build):
			_selected_builds.erase(build)
		_pendingRemovedBuilds[build] = true
	build_manager.delBuilds(builds)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)

#tag buildLayer连续放置元件结束
func on_place_drag_ended() -> void:
	var v := _get_view()
	if v == null:
		return
	if _pendingPlacedBuilds.is_empty():
		return
	var placedBuilds:Array[SWBuildItemDefine] = _pendingPlacedBuilds.keys()
	_pendingPlacedBuilds.clear()
	var notifyBuilds = placedBuilds.duplicate()
	if circuit_control:
		notifyBuilds.append_array(circuit_control.updateBuildCircuit(placedBuilds))
	var notifyChunkPosArr = getNotifyChunkPosArr(notifyBuilds)
	_get_view().sw_draw_manager.updataChunks(notifyChunkPosArr)
	for build in notifyBuilds:
		if build is SWBuildClockSiggen:
			addClockBuild(build)

#tag buildLayer连续删除元件结束
func on_erase_drag_ended() -> void:
	var v := _get_view()
	if v == null:
		return
	if _pendingRemovedBuilds.is_empty():
		return
	var removedBuilds:Array[SWBuildItemDefine] = _pendingRemovedBuilds.keys()
	_pendingRemovedBuilds.clear()
	var notifyBuilds = removedBuilds.duplicate()
	if circuit_control:
		notifyBuilds.append_array(circuit_control.updateBuildCircuit(removedBuilds))
	var notifyChunkPosArr = getNotifyChunkPosArr(notifyBuilds)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	for build in removedBuilds:
		if build is SWBuildClockSiggen:
			delClockBuild(build)

#tag 拖拽开始
func on_drag_started() -> void:
	pass
	
#tag 拖拽结束
func on_drag_ended() -> void:
	pass
	
#tag 框选元件(低性能)
func on_select_by_rect(rect:Rect2) -> void:
	var v := _get_view()
	if v == null:
		return
	var builds := build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		_selected_builds[build] = true
		build_manager.setBuildState(build,SwDefine.BuildState.SELECTED)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	
#tag 取消框选元件(低性能)
func on_deselect_by_rect(rect:Rect2) -> void:
	var v := _get_view()
	if v == null:
		return
	var builds := build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		if _selected_builds.has(build):
			_selected_builds.erase(build)
			build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
	v.sw_draw_manager.updataChunks(notifyChunkPosArr)
#endregion

#region 内部函数
#tag buildLayer根据建筑物坐标获取区块坐标
func getNotifyChunkPosArr(builds:Array[SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		build.markRenderPartsDirty()
		var chunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

#tag buildLayer获取选中元件中心点置
func _getSelectedBuildCenter() -> Vector2i:
	if _selected_builds.size() == 0:
		return Vector2i.ZERO
	var minPos := Vector2i(999999, 999999)
	var maxPos := Vector2i(-999999, -999999)
	for build in _selected_builds:
		var pos = build.buildAxisPos
		minPos.x = min(minPos.x, pos.x)
		minPos.y = min(minPos.y, pos.y)
		maxPos.x = max(maxPos.x, pos.x)
		maxPos.y = max(maxPos.y, pos.y)
	var center = (minPos + maxPos) / 2
	var gs = Vector2(SwDefine.GRID_SIZE)
	return Vector2i((Vector2(center) / gs).floor() * gs)

#endregion

#region 外部调用操作地图
#tag 设置手持系统
func set_hold_system(hold_sys:SWHoldLayerSystem) -> void:
	_hold_system = hold_sys
	
#tag 清除地图上所有元件
func clear_all_builds() -> void:
	_pendingRemovedBuilds.clear()
	_pendingPlacedBuilds.clear()
	_selected_builds.clear()
	build_manager.clearAllBuilds()
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataAllChunks()

#加载存档数据
func load_save_data(data: Dictionary) -> void:
	clear_all_builds()
	var builds_arr = data.get("builds", [])
	if not builds_arr is Array:
		return
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
		var build = SwDefine.SWBuildCreator(pos, build_def, rot)
		build.circuit_on = circuit_on
		build.signal_state = signal_state
		build.in_loop = in_loop
		build_manager.addBuild(build)
	circuit_control.updateBuildCircuit(build_manager.getAllBuilds())
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataAllChunks()
		v.sw_draw_manager.on_view_rect_changed()
#endregion

#region buildLayer事件(剪切、复制、删除选中、建筑物点击)
#tag buildLayer剪切
func _do_cut() -> void:
	if _selected_builds.size() == 0:
		return
	if not _hold_system:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in _selected_builds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	_hold_system.set_hold_builds(builds, center)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	build_manager.delBuilds(builds)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
	_selected_builds.clear()

#tag buildLayer复制
func _do_copy() -> void:
	if _selected_builds.size() == 0:
		return
	if not _hold_system:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in _selected_builds:
		builds.append(build)
	var center = _getSelectedBuildCenter()
	_hold_system.set_hold_builds(builds, center)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		build_manager.setBuildState(build,SwDefine.BuildState.IDLE)
	_selected_builds.clear()
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)

#tag buildLayer删除选中
func _do_delete_selected() -> void:
	if _selected_builds.size() == 0:
		return
	var builds:Array[SWBuildItemDefine] = []
	for build in _selected_builds:
		builds.append(build)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	_selected_builds.clear()
	build_manager.delBuilds(builds)
	var v := _get_view()
	if v != null:
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)

#tag buildLayer删除选中、剪切、复制
func _on_event_key(event: InputEventKey) -> bool:
	if event.is_pressed():
		if event.keycode == KEY_DELETE:
			_do_delete_selected()
			return true
		if event.ctrl_pressed and _selected_builds.size() > 0:
			if event.keycode == KEY_X:
				_do_cut()
				return true
			elif event.keycode == KEY_C:
				_do_copy()
				return true
	return false
	
#tag buildLayer左键按下	
func _on_left_pressed(v:SWBuildLayer) -> bool:
	var viewport := v.get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_pos, viewport)
	var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(world_pos))
	var build = build_manager.getBuild(grid_pos)
	#print("[Build] grid=", grid_pos, " build=", build, " total=", build_manager.getAllBuilds().size())
	if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
		if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
			#tag 地图上的元件被点击
			build.onPressed(true)
		elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
			build.onPressed(!build.pressed)
		var newBuilds = circuit_control.buildSignalChanged(build)
		newBuilds.append(build)
		var notifyChunkPosArr = getNotifyChunkPosArr(newBuilds)
		v.sw_draw_manager.updataChunks(notifyChunkPosArr)
		if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
			_pressed_button_pos = grid_pos
		v.get_viewport().set_input_as_handled()
		return true
	return false
	
#tag buildLayer左键释放
func _on_left_released(v:SWBuildLayer) -> bool:
	if _pressed_button_pos != Vector2i(-9999, -9999):
		var grid_pos:Vector2i = SwCommon.GetGridPos(Vector2i(_pressed_button_pos))
		var build = build_manager.getBuild(grid_pos)
		if build and (build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH):
			if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.BUTTON:
				#tag 地图上的元件被点击释放
				build.onPressed(false)
			elif build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.SWITCH:
				pass
			var newBuilds = circuit_control.buildSignalChanged(build)
			newBuilds.append(build)
			var notifyChunkPosArr = getNotifyChunkPosArr(newBuilds)
			v.sw_draw_manager.updataChunks(notifyChunkPosArr)
		_pressed_button_pos = Vector2i(-9999, -9999)
		return true
	return false
	
#tag buildLayer鼠标事件
func _on_event_mouse_button(event: InputEventMouseButton) -> bool:
	var v := _get_view()
	if v == null:
		return false
	if event.is_pressed():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_pressed(v)
	elif event.is_released():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_released(v)
	return false
	
#tag buildLayer事件
func handle_input(event: InputEvent) -> bool:
	if _get_view() == null:
		return false
	if event is InputEventKey:
		return _on_event_key(event as InputEventKey)
	elif event is InputEventMouseButton:
		return _on_event_mouse_button(event as InputEventMouseButton)
	return false
	
#endregion

#region 建筑物时钟每帧更新
#tag 建筑物时钟每帧更新
var clockBuildArr:Dictionary[SWBuildItemDefine,bool] = {}
const CLOCK_GAP_TIME = 1.0/60
var curTimeGap:float = 0
func addClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr[build]=true
func delClockBuild(build:SWBuildItemDefine) -> void:
	clockBuildArr.erase(build)
func tick(_delta: float,_tick_index:int) -> void:
	curTimeGap+=_delta
	var changedBuilds:Array[SWBuildItemDefine] = []
	if curTimeGap > CLOCK_GAP_TIME*2:
		curTimeGap = 0
		for build in clockBuildArr.keys():
			build.onPressed(true)
			var newBuilds = circuit_control.buildSignalChanged(build)
			changedBuilds.append_array(newBuilds)
		if changedBuilds.size() > 0:
			var v := _get_view()
			if v != null:
				var notifyChunkPosArr = getNotifyChunkPosArr(changedBuilds)
				v.sw_draw_manager.updataChunks(notifyChunkPosArr)
#endregion
