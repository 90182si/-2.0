class_name SWHoldLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager
@onready var sw_draw_manager_2: SWDrawManager = $SWDrawManager2
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
var _cur_hold_builds:Array[SWDefine.SWBuildItemDefine] = []

signal holdIdleBuilds(builds,posArr)
signal holdRemoveBuilds(posArr)
signal selectBuildsByRect(rect)

func _idle_builds_between(from_world_pos: Vector2, to_world_pos: Vector2) -> void:
	#if not left_mouse_pressed:
		#return
	if _cur_hold_builds.size() != 1 and left_mouse_pressed:
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
	sw_draw_manager_2.setDrawMode(SWDefine.GridDrawMode.HoldShadow)
	sw_draw_manager.useName = "Hold"
	sw_draw_manager_2.useName = "Shadow"
	select_rect.set_visible(false)
	
	# 初始化优化定时器
	_setup_select_optimization()
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	sw_draw_manager_2.on_view_rect_changed(viewRect,speedVec)
	pass

func on_sel_tool_draw_data(drawData:SWDrawData) -> void:
	var drawData2:SWDrawData = SWDrawData.new()
	sw_draw_manager.setHoldBuild(drawData)
	for mapData in drawData.mapDatas:
		drawData2.addOneDrawBuildDefine(mapData.buildAxisPos,_hold_shadow_define)
	sw_draw_manager_2.setHoldBuild(drawData2)
	_hold_pos_inited = false
	_cur_hold_builds = drawData.mapDatas

#func on_sel_tool(buildDefine:SWBuildDefine) -> void:
	#var drawData:SWDrawData = SWDrawData.new()
	#drawData.addOneDrawBuildDefine(Vector2i(0,0),buildDefine)
	#sw_draw_manager.setHoldBuild(drawData)
	#var drawData2:SWDrawData = SWDrawData.new()
	#drawData2.addOneDrawBuildDefine(Vector2i(0,0),_hold_shadow_define)
	#sw_draw_manager_2.setHoldBuild(drawData2)
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
	sw_draw_manager_2.setHoldBuildsPos(_hold_smoothed_world_pos)
	
	if left_mouse_pressed:
		var grid_world_pos := getCurGridWorldPosByMouse()
		_idle_builds_between(last_world_pos, grid_world_pos)

var last_world_pos:Vector2i
var left_mouse_pressed = false
var right_mouse_pressed = false
var ctrl_pressed = false
var selectRectPos:Vector2
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.is_pressed():
			if event.button_index == MOUSE_BUTTON_RIGHT:
				if _cur_hold_builds.size() > 0:
					sw_draw_manager.setHoldBuild(null) 
					sw_draw_manager_2.setHoldBuild(null) 
					_hold_pos_inited = false
					_cur_hold_builds.clear()
				else:
					last_world_pos = getCurGridWorldPosByMouse()
					var poss:Array[Vector2i] = []
					poss.append(last_world_pos)
					holdRemoveBuilds.emit(poss)
					right_mouse_pressed = true
			elif event.button_index == MOUSE_BUTTON_LEFT:
				left_mouse_pressed = true
				if _cur_hold_builds.size() > 0:
					last_world_pos = getCurGridWorldPosByMouse()
					var poss:Array[Vector2i] = []
					var centerPos = sw_draw_manager_2.getHoldCenter()-Vector2(64,64)
					poss.append(last_world_pos-Vector2i(centerPos))
					holdIdleBuilds.emit(_cur_hold_builds,poss)
					#print("idle")
				else:
					var world_pos = getCurWorldPosByMouse()
					select_rect.position = world_pos
					selectRectPos = world_pos
		elif event.is_released():
			if event.button_index == MOUSE_BUTTON_LEFT:
				left_mouse_pressed = false
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				right_mouse_pressed = false
	elif event is InputEventMouseMotion:
		if not ctrl_pressed:
			var world_pos = getCurGridWorldPosByMouse()
			if left_mouse_pressed:
				_idle_builds_between(last_world_pos, world_pos)
			elif right_mouse_pressed:
				_idle_builds_between(last_world_pos, world_pos)
		else:
			if left_mouse_pressed:
				var world_pos_mouse := getCurWorldPosByMouse()
				select_rect.size = abs(world_pos_mouse-selectRectPos)
				var pos1 = selectRectPos
				var pos2 = selectRectPos+world_pos_mouse-selectRectPos
				select_rect.position.x = min(pos1.x,pos2.x)
				select_rect.position.y = min(pos1.y,pos2.y)
				# 使用优化后的选择发射
				_handle_optimized_select_builds(world_pos_mouse, select_rect.get_rect())
	elif event is InputEventKey:
		if Input.is_action_pressed("Rotation"):
			var drawData = sw_draw_manager.getHoldBuild()
			var centerPos = sw_draw_manager_2.getHoldCenter()-Vector2(64,64)
			for data:SWDefine.SWBuildItemDefine in drawData.mapDatas:
				data.buildAxisPos = SWCommon.RotationPos(data.buildAxisPos,90,centerPos).snapped(Vector2(128,128))
				data.rotation-=90
				data.rotation%=360
			sw_draw_manager.updataAllChunks()
		else:
			if Input.is_key_pressed(KEY_CTRL) and _cur_hold_builds.size() == 0:
				ctrl_pressed = true
				select_rect.set_visible(true)
			else:
				select_rect.size = Vector2(0,0)
				select_rect.set_visible(false)
				ctrl_pressed = false
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
