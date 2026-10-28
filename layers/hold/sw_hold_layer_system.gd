class_name SWHoldLayerSystem extends SWLayerSystem

#region 信号
signal hold_idle_builds(builds:Array,posistions:Array)
signal hold_remove_builds(posistions:Array)
signal select_builds_by_rect(rect:Rect2)
signal deselect_builds_by_rect(rect:Rect2)
signal drag_started()
signal drag_ended()
signal place_drag_ended()
signal erase_drag_ended()
#endregion

#region 成员变量
var sel_tunnel:bool = false

var _hold_builds:Array[SWBuildItemDefine] = []
var _last_world_pos:Vector2i = Vector2i.ZERO
var _left_mouse_pressed:bool = false
var _right_mouse_pressed:bool = false
var _ctrl_pressed:bool = false
var _selectRectPos:Vector2 = Vector2.ZERO

var _right_ctrl_dragging:bool = false
var _left_drag_started:bool = false
var _right_drag_started:bool = false
var _drag_count: int = 0
var _last_anchor_pos: Vector2i = Vector2i.ZERO

var _hold_smoothed_world_pos:Vector2 = Vector2.ZERO
var _hold_smoothed_world_vel:Vector2 = Vector2.ZERO
var _hold_pos_inited:bool = false
#endregion

func _init() -> void:
	system_name = &"core.layer.hold"
	run_order = SwDefine.ORDER_LAYER_HOLD
	receives_frame = true

func _get_view() -> SWHoldLayer:
	return view as SWHoldLayer

func attach_view(v:SWLayer) -> void:
	super.attach_view(v)
	var holdLayer = v as SWHoldLayer
	if holdLayer != null:
		if not holdLayer.selectBuildsByRect.is_connected(_on_select_builds_by_rect):
			holdLayer.selectBuildsByRect.connect(_on_select_builds_by_rect)

func frame(_delta:float) -> void:
	var v = _get_view()
	if v == null:
		return
	var world_pos = v.get_mouse_world_pos()
	v.set_hold_draw_pos(get_smoothed_pos(_delta,world_pos,v))
	if _left_mouse_pressed:
		var anchor_pos = v.get_anchor_pos(world_pos)
		if anchor_pos == _last_anchor_pos:
			return
		_paint_between(_last_anchor_pos, Vector2(anchor_pos))
		_last_anchor_pos = anchor_pos
	
#region 内部函数
func get_smoothed_pos(_delta:float,world_pos:Vector2,v:SWHoldLayer) -> Vector2:
	if not _hold_pos_inited:
		_hold_smoothed_world_pos = world_pos
		_hold_smoothed_world_vel = Vector2.ZERO
		_hold_pos_inited = true
	else:
		# 二阶弹簧/阻尼模型（可回弹）
		var hz: float = maxf(0.0, v.hold_spring_frequency_hz)
		var zeta: float = maxf(0.0, v.hold_damping_ratio)
		var omega: float = TAU * hz
		# 大 delta 时分段积分，减少不稳定和穿透
		var remaining: float = minf(_delta, 0.25)
		var max_step: float = maxf(0.0005, v.hold_max_substep)
		while remaining > 0.0:
			var dt: float = minf(remaining, max_step)
			remaining -= dt
			# a = -2ζω v - ω² (x - target)
			var x_err: Vector2 = _hold_smoothed_world_pos - world_pos
			var accel: Vector2 = (-2.0 * zeta * omega) * _hold_smoothed_world_vel - (omega * omega) * x_err
			_hold_smoothed_world_vel += accel * dt
			_hold_smoothed_world_pos += _hold_smoothed_world_vel * dt
	return _hold_smoothed_world_pos
func _on_select_builds_by_rect(rect:Rect2) -> void:
	select_builds_by_rect.emit(rect)
func _begin_drag() -> void:
	if _drag_count == 0:
		drag_started.emit()
	_drag_count += 1
func _end_drag() -> void:
	_drag_count -= 1
	if _drag_count <= 0:
		_drag_count = 0
		drag_ended.emit()
func _rot_hold(times:int = 1) -> void:
	var v = _get_view()
	if v == null:
		return
	var drawData = v.get_hold_draw_data()
	if drawData == null:
		return
	var chunk_map:Dictionary[Vector2i,bool]={}
	for data:SWBuildItemDefine in drawData.mapDatas:
		for time in times:
			@warning_ignore("static_called_on_instance","integer_division")
			data.buildAxisPos = SwCommon.RotationPos(
				data.buildAxisPos+SwDefine.GRID_SIZE/2,90,Vector2.ZERO
			)-Vector2(SwDefine.GRID_SIZE/2)
			data.buildAxisPos = data.buildAxisPos.snapped(SwDefine.GRID_SIZE)
			@warning_ignore("static_called_on_instance")
			chunk_map[SwCommon.GetChunkPos(data.buildAxisPos)]=true
			data.rotOnce()
	
	var shadowData = v.get_shadow_draw_data()
	if shadowData:
		for i in min(drawData.mapDatas.size(), shadowData.mapDatas.size()):
			shadowData.mapDatas[i].buildAxisPos = drawData.mapDatas[i].buildAxisPos
			shadowData.mapDatas[i].rotation = drawData.mapDatas[i].rotation
	v.refresh_hold_render(chunk_map.keys())
	_hold_pos_inited = false
func _clear_hold() -> void:
	var v := _get_view()
	if v != null:
		v.clear_hold()
		# 准备阶段可能把预览设成隐藏：清空时恢复，避免下次手持直接不可见
		v.set_hold_visible(true)
	_hold_builds.clear()
	sel_tunnel=false
	_hold_pos_inited = false	
func _paint_between(from_world_pos: Vector2, to_world_pos: Vector2) -> void:
	if _hold_builds.is_empty() and _left_mouse_pressed:
		return
	var grid_size_v := Vector2(SwDefine.GRID_SIZE)
	var last_grid_index:Vector2i = Vector2i(from_world_pos / grid_size_v)
	var cur_grid_index:Vector2i = Vector2i(to_world_pos / grid_size_v)
	if last_grid_index == cur_grid_index:
		return
	var x0:int = last_grid_index.x
	var y0:int = last_grid_index.y
	var x1:int = cur_grid_index.x
	var y1:int = cur_grid_index.y
	var dx:int = abs(x1 - x0)
	var dy:int = -abs(y1 - y0)
	var sx:int = 0
	if x0 < x1:
		sx = 1
	elif x0 > x1:
		sx = -1
	var sy:int = 0
	if y0 < y1:
		sy = 1
	elif y0 > y1:
		sy = -1
	var err:int = dx + dy
	var poss:Array[Vector2i] = []
	var x:int = x0
	var y:int = y0
	while true:
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy
		poss.append(Vector2i(x, y) * SwDefine.GRID_SIZE)

	if poss.size() == 0:
		return

	if _left_mouse_pressed:
		hold_idle_builds.emit(_hold_builds,poss)
	elif _right_mouse_pressed:
		hold_remove_builds.emit(poss)
	_last_world_pos = to_world_pos
#endregion

#region 外部输入事件
func _on_left_pressed(v:SWHoldLayer) -> bool:
	# 复制/剪切准备期间既不能放置也不能开始框选
	if not _can_place_now():
		return false
	_left_mouse_pressed = true
	if _hold_builds.size() > 0:
		var world_pos = v.get_mouse_world_pos()
		var anchorPos = v.get_anchor_pos(world_pos)
		_last_anchor_pos = anchorPos
		_left_drag_started = true
		_begin_drag()
		hold_idle_builds.emit(_hold_builds,[anchorPos])
		if _hold_builds.size() > 1:
			_left_mouse_pressed = false
		return true
	var world_pos2 = v.get_mouse_world_pos()
	v.set_select_rect_origin(world_pos2,Color(0.557, 1.0, 1.0, 0.3))
	_selectRectPos = world_pos2
	return false
func _on_right_pressed(v:SWHoldLayer) -> bool:
	# 清空手持不碰地图，也不影响已入队的放置任务：放置没跑完也要能随时收手
	if _hold_builds.size() > 0:
		_clear_hold()
		return false
	# 擦除会打断分阶段的电路重建：后台任务期间一律不响应
	if not _can_erase_now():
		return false
	if _ctrl_pressed:
		_right_ctrl_dragging = true
		var world_pos = v.get_mouse_world_pos()
		v.set_select_rect_origin(world_pos,Color(1.0, 0.2, 0.2, 0.3))
		_selectRectPos = world_pos
	else:
		_last_world_pos = v.get_mouse_grid_world_pos()
		_right_drag_started = true
		_begin_drag()
		var remove_positions:Array[Vector2i] = [_last_world_pos]
		hold_remove_builds.emit(remove_positions)
		_right_mouse_pressed = true
	return false
func _on_left_released(_v:SWHoldLayer) -> bool:
	_left_mouse_pressed = false
	if not _left_drag_started:
		return false
	_left_drag_started = false
	_end_drag()
	place_drag_ended.emit()
	if sel_tunnel:
		_rot_hold(2)
	return false
func _on_right_released(v:SWHoldLayer) -> bool:
	if _right_ctrl_dragging:
		_right_ctrl_dragging = false
		var rect = v.get_select_rect()
		if rect.size.x > 5 and rect.size.y > 5:
			deselect_builds_by_rect.emit(rect)
		v.hide_select_rect()
		_ctrl_pressed = false
		return false
	_right_mouse_pressed = false
	if _right_drag_started:
		_right_drag_started = false
		_end_drag()
		erase_drag_ended.emit()
	return false
func _handle_mouse_button(event:InputEventMouseButton) -> bool:
	var v := _get_view()
	if event.is_pressed():
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _on_left_pressed(v):
				return true
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_on_right_pressed(v)
	elif event.is_released():
		if event.button_index == MOUSE_BUTTON_LEFT:
			_on_left_released(v)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_on_right_released(v)
	return false
func _handle_mouse_motion(_event:InputEventMouseMotion) -> bool:
	var v = _get_view()
	if not _ctrl_pressed:
		if _left_mouse_pressed:
			var saved_last = _last_world_pos
			var anchor_pos = v.get_anchor_pos(v.get_mouse_world_pos())
			_paint_between(_last_anchor_pos, Vector2(anchor_pos))
			_last_anchor_pos = anchor_pos
			_last_world_pos = saved_last
		elif _right_mouse_pressed:
			_paint_between(_last_world_pos, v.get_mouse_grid_world_pos())
		return false
	var world_pos_mouse := v.get_mouse_world_pos()
	if _right_ctrl_dragging:
		v.update_select_rect(_selectRectPos,world_pos_mouse)
	elif _left_mouse_pressed:
		var rect:Rect2 = v.update_select_rect(_selectRectPos,world_pos_mouse)
		v.request_select_by_rect(rect)
	return false
func _handle_key(_event:InputEventKey) -> bool:
	var v = _get_view()
	if Input.is_action_pressed("Rotation"):
		_rot_hold(1)
		return false
	if Input.is_key_pressed(KEY_CTRL) and _hold_builds.size() == 0:
		_ctrl_pressed = true
		v.show_select_rect()
		return false
	v.hide_select_rect()
	_ctrl_pressed = false
	_right_ctrl_dragging = false
	v.reset_select_color()
	v.reset_select_throttle()
	return false
func handle_input(event:InputEvent) -> bool:
	if _get_view() == null:
		return false
	if event is InputEventMouseButton:
		return _handle_mouse_button(event as InputEventMouseButton)
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_handle_key(event as InputEventKey)
	return false
#endregion

#region 设置函数
#放置/擦除闸门：由 build 系统注入。复制准备期间两把都关；放置任务期间只关擦除
var _place_gate:Callable = Callable()
var _erase_gate:Callable = Callable()

func set_edit_gates(place_gate:Callable, erase_gate:Callable) -> void:
	_place_gate = place_gate
	_erase_gate = erase_gate

func _can_place_now() -> bool:
	return not _place_gate.is_valid() or bool(_place_gate.call())

func _can_erase_now() -> bool:
	return not _erase_gate.is_valid() or bool(_erase_gate.call())

func set_hold_tool(build_define:SWBuildDefine) -> void:
	if build_define == null:
		_clear_hold()
		return
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),build_define)
	set_hold_draw_data(drawData)
# 真正的置手持逻辑：视图只负责画，数据全在系统里
func set_hold_draw_data(draw_data:SWDrawData) -> void:
	var v := _get_view()
	if v == null:
		return
	if draw_data == null or draw_data.mapDatas.is_empty():
		_clear_hold()
		return
	var shadow_define := v.get_hold_shadow_define()
	var shadow_data := SWDrawData.new()
	if shadow_define != null:
		for data:SWBuildItemDefine in draw_data.mapDatas:
			shadow_data.addOneDrawBuildDefine(data.buildAxisPos, shadow_define, data.rotation)
	install_prepared_hold(draw_data, shadow_data, true)
# 安装已分帧准备好的手持数据（复制/剪切的准备协程调用）：
# mapDatas 与 shadowData 都必须由调用方建好，这里只做挂接，避免一次性创建上万份克隆
func install_prepared_hold(draw_data:SWDrawData, shadow_data:SWDrawData, make_visible:bool) -> void:
	var v := _get_view()
	if v == null or draw_data == null or draw_data.mapDatas.is_empty():
		_clear_hold()
		return
	_hold_builds.clear()
	_hold_builds.assign(draw_data.mapDatas)
	v.install_hold_prepared(draw_data, shadow_data, make_visible)
	v.refresh_hold_render([])
	_hold_pos_inited = false
# 准备阶段开始：旧手持立即清掉并隐藏，准备完成后才会重新出现
func clear_hold_for_prepare() -> void:
	_clear_hold()
	set_hold_visible(false)
func set_hold_visible(enable:bool) -> void:
	var v := _get_view()
	if v != null:
		v.set_hold_visible(enable)
func is_hold_render_idle() -> bool:
	var v := _get_view()
	return v.is_hold_render_idle() if v != null else true
func get_hold_pending_count() -> int:
	var v := _get_view()
	return v.get_hold_pending_count() if v != null else 0
func get_hold_shadow_define() -> SWBuildDefine:
	var v := _get_view()
	return v.get_hold_shadow_define() if v != null else null
func set_hold_builds(builds:Array[SWBuildItemDefine], center:Vector2i) -> void:
	if builds.is_empty():
		_clear_hold()
		return
	var draw_data := SWDrawData.new()
	for build in builds:
		draw_data.addOneDrawBuildDefine(build.buildAxisPos - center, build.buildDefine, build.rotation)
	set_hold_draw_data(draw_data)
func is_hold_empty() -> bool:
	return _hold_builds.is_empty()
func rotate_hold(times:int = 1) -> void:
	_rot_hold(times)
func set_tunnel_mode(value:bool) -> void:
	sel_tunnel = value
#endregion
