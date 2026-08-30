class_name SWHoldLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager
@onready var sw_draw_manager_shadow: SWDrawManager = $SWDrawManager2
@onready var select_rect: ColorRect = $SelectRect

# 优化相关变量
@onready var _select_throttle_timer: Timer = Timer.new()
var _last_select_emit_time: int = 0
var _select_emit_interval: int = 100  # 毫秒
var _pending_select_rect: Rect2 = Rect2(0,0,0,0)
var _last_mouse_pos_for_select: Vector2 = Vector2.ZERO
var _select_distance_threshold: float = 15.0  # 像素
var _last_emit_select_rect: Rect2 = Rect2(0,0,0,0)

@export var _hold_shadow_define:SWBuildDefine

@export var hold_spring_frequency_hz: float = 6.0
@export var hold_damping_ratio: float = 0.7
@export var hold_max_substep: float = 1.0 / 60.0

var _hold_smoothed_world_pos: Vector2
var _hold_smoothed_world_vel := Vector2.ZERO
var _hold_pos_inited := false
var _cur_hold_builds:Array[SWBuildItemDefine] = []

signal holdIdleBuilds(builds,posArr)
signal holdRemoveBuilds(posArr)
signal selectBuildsByRect(rect)
signal deselectBuildsByRect(rect)
signal drag_started()
signal drag_ended()

var _drag_count: int = 0
var _last_anchor_pos: Vector2i = Vector2i.ZERO

func _get_anchor_pos(worldPos: Vector2) -> Vector2i:
	var centerOffset = sw_draw_manager_shadow.getHoldCenter()
	return SWCommon.GetGridPos(Vector2i(worldPos - centerOffset + Vector2(SWDefine.GRID_SIZE / 2)))

func _begin_drag() -> void:
	if _drag_count == 0:
		drag_started.emit()
	_drag_count += 1

func _end_drag() -> void:
	_drag_count -= 1
	if _drag_count <= 0:
		_drag_count = 0
		drag_ended.emit()

func _idle_builds_between(from_world_pos: Vector2, to_world_pos: Vector2) -> void:
	#if not left_mouse_pressed:
		#return
	if _cur_hold_builds.is_empty() and left_mouse_pressed:
		return
	
	var grid_size_v := Vector2(SWDefine.GRID_SIZE)
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

		var grid_world_pos:Vector2i = Vector2i(Vector2i(x, y) * SWDefine.GRID_SIZE)
		poss.append(grid_world_pos)

	if poss.size() == 0:
		return

	if left_mouse_pressed:
		holdIdleBuilds.emit(_cur_hold_builds,poss)
	elif right_mouse_pressed:
		holdRemoveBuilds.emit(poss)
	last_world_pos = to_world_pos

func _ready() -> void:
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.ByHold)
	sw_draw_manager_shadow.setDrawMode(SWDefine.GridDrawMode.HoldShadow)
	sw_draw_manager.useName = "Hold"
	sw_draw_manager_shadow.useName = "Shadow"
	select_rect.set_visible(false)
	
	# 初始化优化定时器
	_setup_select_optimization()
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	sw_draw_manager_shadow.on_view_rect_changed(viewRect,speedVec)
	pass

func on_sel_tool_draw_data(drawData:SWDrawData) -> void:
	var drawData2:SWDrawData = SWDrawData.new()
	sw_draw_manager.setHoldBuild(drawData)
	for mapData in drawData.mapDatas:
		drawData2.addOneDrawBuildDefine(mapData.buildAxisPos,_hold_shadow_define)
	sw_draw_manager_shadow.setHoldBuild(drawData2)
	_hold_pos_inited = false
	_cur_hold_builds = drawData.mapDatas

func setHeldBuilds(builds:Array[SWBuildItemDefine], centerPos:Vector2i) -> void:
	if builds.size() == 0:
		return
	var drawData:SWDrawData = SWDrawData.new()
	for build in builds:
		var relPos = build.buildAxisPos - centerPos
		var clone = SWDefine.SWBuildCreator(relPos, build.buildDefine, build.rotation)
		drawData.mapDatas.append(clone)
	on_sel_tool_draw_data(drawData)

#func on_sel_tool(buildDefine:SWBuildDefine) -> void:
	#var drawData:SWDrawData = SWDrawData.new()
	#drawData.addOneDrawBuildDefine(Vector2i(0,0),buildDefine)
	#sw_draw_manager.setHoldBuild(drawData)
	#var drawData2:SWDrawData = SWDrawData.new()
	#drawData2.addOneDrawBuildDefine(Vector2i(0,0),_hold_shadow_define)
	#sw_draw_manager_shadow.setHoldBuild(drawData2)
	#_hold_pos_inited = false
	#
	#_cur_hold_builds = drawData.mapDatas
	#pass
	
func getCurWorldPosByMouse() -> Vector2:
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	## 视口坐标转为世界坐标（canvas 坐标）
	var world_pos = SWCommon.GetGlobalPosByViewPos(mouse_pos,viewport)
	return world_pos

func getCurGridWorldPosByMouse() -> Vector2:
	var world_pos := getCurWorldPosByMouse()
	var grid_pos:Vector2i = SWCommon.GetGridPos(Vector2i(world_pos))
	return Vector2(grid_pos)
	
func _process(delta: float) -> void:
	
	var world_pos = getCurWorldPosByMouse()
	if not _hold_pos_inited:
		_hold_smoothed_world_pos = world_pos
		_hold_smoothed_world_vel = Vector2.ZERO
		_hold_pos_inited = true
	else:
		# 二阶弹簧/阻尼模型（可回弹）
		var hz: float = maxf(0.0, hold_spring_frequency_hz)
		var zeta: float = maxf(0.0, hold_damping_ratio)
		var omega: float = TAU * hz
		
		# 大 delta 时分段积分，减少不稳定和穿透
		var remaining: float = minf(delta, 0.25)
		var max_step: float = maxf(0.0005, hold_max_substep)
		while remaining > 0.0:
			var dt: float = minf(remaining, max_step)
			remaining -= dt
			
			# a = -2ζω v - ω² (x - target)
			var x_err: Vector2 = _hold_smoothed_world_pos - world_pos
			var accel: Vector2 = (-2.0 * zeta * omega) * _hold_smoothed_world_vel - (omega * omega) * x_err
			_hold_smoothed_world_vel += accel * dt
			_hold_smoothed_world_pos += _hold_smoothed_world_vel * dt
	
	sw_draw_manager.setHoldBuildsPos(_hold_smoothed_world_pos)
	sw_draw_manager_shadow.setHoldBuildsPos(_hold_smoothed_world_pos)
	
	if left_mouse_pressed:
		var saved_last = last_world_pos
		var world_pos_2 := getCurWorldPosByMouse()
		var anchorPos = _get_anchor_pos(world_pos_2)
		_idle_builds_between(_last_anchor_pos, Vector2(anchorPos))
		_last_anchor_pos = anchorPos
		last_world_pos = saved_last

var last_world_pos:Vector2i
var left_mouse_pressed = false
var right_mouse_pressed = false
var ctrl_pressed = false
var selectRectPos:Vector2
var _right_ctrl_dragging:bool = false
var _left_drag_started:bool = false
var _right_drag_started:bool = false
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_RIGHT:
				if _cur_hold_builds.size() > 0:
					sw_draw_manager.setHoldBuild(null) 
					sw_draw_manager_shadow.setHoldBuild(null) 
					_hold_pos_inited = false
					_cur_hold_builds.clear()
				elif ctrl_pressed:
					_right_ctrl_dragging = true
					var world_pos = getCurWorldPosByMouse()
					select_rect.color = Color(1.0, 0.2, 0.2, 0.3)
					select_rect.position = world_pos
					selectRectPos = world_pos
				else:
					last_world_pos = getCurGridWorldPosByMouse()
					var poss:Array[Vector2i] = []
					poss.append(last_world_pos)
					_right_drag_started = true
					_begin_drag()
					holdRemoveBuilds.emit(poss)
					right_mouse_pressed = true
			elif event.button_index == MOUSE_BUTTON_LEFT:
				#90182si 鼠标连续操作
				left_mouse_pressed = false
				if _cur_hold_builds.size() > 0:
					var world_pos = getCurWorldPosByMouse()
					var anchorPos = _get_anchor_pos(world_pos)
					var poss:Array[Vector2i] = []
					poss.append(anchorPos)
					_last_anchor_pos = anchorPos
					_left_drag_started = true
					_begin_drag()
					holdIdleBuilds.emit(_cur_hold_builds,poss)
					if _cur_hold_builds.size() > 1:
						left_mouse_pressed = false
					get_viewport().set_input_as_handled()
					#print("idle")
				else:
					var world_pos = getCurWorldPosByMouse()
					select_rect.color = Color(0.557, 1.0, 1.0, 0.3)
					select_rect.position = world_pos
					selectRectPos = world_pos
		elif event.is_released():
			if event.button_index == MOUSE_BUTTON_LEFT:
				left_mouse_pressed = false
				if _left_drag_started:
					_left_drag_started = false
					_end_drag()
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				if _right_ctrl_dragging:
					_right_ctrl_dragging = false
					var rect = select_rect.get_rect()
					if rect.size.x > 5 and rect.size.y > 5:
						deselectBuildsByRect.emit(rect)
					select_rect.size = Vector2(0,0)
					select_rect.set_visible(false)
					ctrl_pressed = false
				else:
					right_mouse_pressed = false
					if _right_drag_started:
						_right_drag_started = false
						_end_drag()
	elif event is InputEventMouseMotion:
		if not ctrl_pressed:
			var world_pos = getCurGridWorldPosByMouse()
			if left_mouse_pressed:
				var saved_last = last_world_pos
				var rawWorldPos = getCurWorldPosByMouse()
				var anchorPos = _get_anchor_pos(rawWorldPos)
				_idle_builds_between(_last_anchor_pos, Vector2(anchorPos))
				_last_anchor_pos = anchorPos
				last_world_pos = saved_last
			elif right_mouse_pressed:
				_idle_builds_between(last_world_pos, world_pos)
		else:
			var world_pos_mouse := getCurWorldPosByMouse()
			if _right_ctrl_dragging:
				select_rect.size = abs(world_pos_mouse-selectRectPos)
				var pos1 = selectRectPos
				var pos2 = selectRectPos+world_pos_mouse-selectRectPos
				select_rect.position.x = min(pos1.x,pos2.x)
				select_rect.position.y = min(pos1.y,pos2.y)
			elif left_mouse_pressed:
				select_rect.size = abs(world_pos_mouse-selectRectPos)
				var pos1 = selectRectPos
				var pos2 = selectRectPos+world_pos_mouse-selectRectPos
				select_rect.position.x = min(pos1.x,pos2.x)
				select_rect.position.y = min(pos1.y,pos2.y)
				_handle_optimized_select_builds(world_pos_mouse, select_rect.get_rect())
	elif event is InputEventKey:
		if Input.is_action_pressed("Rotation"):
			var drawData = sw_draw_manager.getHoldBuild()
			var centerPos = Vector2(0,0)#sw_draw_manager_shadow.getHoldCenter()-Vector2(64,64)
			var chunkPosMap:Dictionary[Vector2i,bool]={}
			for data:SWBuildItemDefine in drawData.mapDatas:
				data.buildAxisPos = SWCommon.RotationPos(data.buildAxisPos+Vector2i(64,64),90,centerPos)-Vector2(64,64)
				data.buildAxisPos = data.buildAxisPos.snapped(Vector2i(128,128))
				chunkPosMap[SWCommon.GetChunkPos(data.buildAxisPos)]=true
				data.rotation+=1
			var shadowData = sw_draw_manager_shadow.getHoldBuild()
			if shadowData:
				for i in min(drawData.mapDatas.size(), shadowData.mapDatas.size()):
					shadowData.mapDatas[i].buildAxisPos = drawData.mapDatas[i].buildAxisPos
					shadowData.mapDatas[i].rotation = drawData.mapDatas[i].rotation
			sw_draw_manager.recalcHoldCenter()
			sw_draw_manager_shadow.recalcHoldCenter()
			sw_draw_manager.updataAllChunks()
			sw_draw_manager.updataChunks(chunkPosMap.keys())
			sw_draw_manager_shadow.updataAllChunks()
			sw_draw_manager_shadow.updataChunks(chunkPosMap.keys())
			_hold_pos_inited = false
		else:
			if Input.is_key_pressed(KEY_CTRL) and _cur_hold_builds.size() == 0:
				ctrl_pressed = true
				select_rect.set_visible(true)
			else:
				select_rect.size = Vector2(0,0)
				select_rect.set_visible(false)
				ctrl_pressed = false
				_right_ctrl_dragging = false
				select_rect.color = Color(0.557, 1.0, 1.0, 0.3)
				# 重置优化状态
				_last_mouse_pos_for_select = Vector2.ZERO
				_last_emit_select_rect = Rect2(0,0,0,0)
				_pending_select_rect = Rect2(0,0,0,0)
	
# 优化相关函数
func _setup_select_optimization() -> void:
	"""设置选择优化定时器"""
	_select_throttle_timer.wait_time = _select_emit_interval / 1000.0
	_select_throttle_timer.one_shot = true
	_select_throttle_timer.timeout.connect(_on_select_throttle_timeout)
	add_child(_select_throttle_timer)

func _on_select_throttle_timeout() -> void:
	"""选择节流定时器回调"""
	if _pending_select_rect != Rect2(0,0,0,0):
		_emit_select_builds_signal(_pending_select_rect)
		_pending_select_rect = Rect2(0,0,0,0)
		_last_select_emit_time = Time.get_ticks_msec()

func _handle_optimized_select_builds(mouse_pos: Vector2, current_rect: Rect2) -> void:
	"""处理优化的选择构建信号"""
	# 检查距离阈值
	if _last_mouse_pos_for_select != Vector2.ZERO:
		var distance = _last_mouse_pos_for_select.distance_to(mouse_pos)
		if distance < _select_distance_threshold:
			return  # 距离太近，忽略
	
	# 检查时间节流
	var current_time = Time.get_ticks_msec()
	if current_time - _last_select_emit_time >= _select_emit_interval:
		_emit_select_builds_signal(current_rect)
		_last_mouse_pos_for_select = mouse_pos
		_last_select_emit_time = current_time
	else:
		# 保存到待处理队列
		_pending_select_rect = current_rect
		if not _select_throttle_timer.is_stopped():
			_select_throttle_timer.stop()
		_select_throttle_timer.start()
		_last_mouse_pos_for_select = mouse_pos

func _emit_select_builds_signal(rect: Rect2) -> void:
	"""发射选择构建信号，避免重复发射相同内容"""
	if _last_emit_select_rect == null or _last_emit_select_rect != rect:
		selectBuildsByRect.emit(rect)
		_last_emit_select_rect = rect

# 优化参数调整函数
func set_select_emit_interval(interval_ms: int) -> void:
	"""动态调整选择发射间隔"""
	_select_emit_interval = interval_ms
	_select_throttle_timer.wait_time = interval_ms / 1000.0

func set_select_distance_threshold(threshold: float) -> void:
	"""动态调整选择距离阈值"""
	_select_distance_threshold = threshold

func get_select_optimization_stats() -> Dictionary:
	"""获取选择优化统计信息"""
	return {
		"emit_interval": _select_emit_interval,
		"distance_threshold": _select_distance_threshold,
		"last_emit_time_ago": Time.get_ticks_msec() - _last_select_emit_time,
		"has_pending_emit": _pending_select_rect != null
	}
