class_name SWHoldLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager
@onready var sw_draw_manager_shadow: SWDrawManager = $SWDrawManager2
@onready var select_rect: ColorRect = $SelectRect

@export var hold_shadow_define:SWBuildDefine
@export var hold_spring_frequency_hz: float = 6.0
@export var hold_damping_ratio: float = 0.7
@export var hold_max_substep: float = 1.0 / 60.0
# 节流后发出，系统转发为 select_by_rect
signal selectBuildsByRect(rect: Rect2)

# =========================================================
# 给 SWHoldLayerSystem 的视图接口
# =========================================================
func get_hold_shadow_define() -> SWBuildDefine:
	return hold_shadow_define
func get_mouse_world_pos() -> Vector2:
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	## 视口坐标转为世界坐标（canvas 坐标）
	var world_pos = SwCommon.GetGlobalPosByViewPos(mouse_pos,viewport)
	return world_pos
func get_mouse_grid_world_pos() -> Vector2i:
	var world_pos := get_mouse_world_pos()
	return SwCommon.GetGridPos(Vector2i(world_pos))
func get_anchor_pos(worldPos: Vector2) -> Vector2i:
	var centerOffset = sw_draw_manager_shadow.getHoldCenter()
	return SwCommon.GetGridPos(Vector2i(worldPos - centerOffset + Vector2(SwDefine.GRID_SIZE / 2)))
func show_hold(draw_data:SWDrawData,shadow_data:SWDrawData) -> void:
	sw_draw_manager.setHoldBuild(draw_data)
	sw_draw_manager_shadow.setHoldBuild(shadow_data)
func clear_hold() -> void:
	sw_draw_manager.setHoldBuild(null)
	sw_draw_manager_shadow.setHoldBuild(null)
func get_hold_draw_data() -> SWDrawData:
	return sw_draw_manager.getHoldBuild()
func get_shadow_draw_data() -> SWDrawData:
	return sw_draw_manager_shadow.getHoldBuild()
func set_hold_draw_pos(world_pos:Vector2) -> void:
	sw_draw_manager.setHoldBuildsPos(world_pos)
	sw_draw_manager_shadow.setHoldBuildsPos(world_pos)
func refresh_hold_render(chunk_positions: Array) -> void:
	sw_draw_manager.recalcHoldCenter()
	sw_draw_manager_shadow.recalcHoldCenter()
	sw_draw_manager.updataAllChunks()
	sw_draw_manager_shadow.updataAllChunks()
	if not chunk_positions.is_empty():
		sw_draw_manager.updataChunks(chunk_positions)
		sw_draw_manager_shadow.updataChunks(chunk_positions)
# ---- 框选矩形 ----
func set_select_rect_origin(pos: Vector2, color: Color) -> void:
	select_rect.color = color
	select_rect.position = pos
func update_select_rect(from_pos: Vector2, to_pos: Vector2) -> Rect2:
	select_rect.size = (to_pos - from_pos).abs()
	select_rect.position = Vector2(minf(from_pos.x, to_pos.x), minf(from_pos.y, to_pos.y))
	return select_rect.get_rect()
func get_select_rect() -> Rect2:
	return select_rect.get_rect()
func show_select_rect() -> void:
	select_rect.visible = true
func hide_select_rect() -> void:
	select_rect.size = Vector2.ZERO
	select_rect.visible = false
func reset_select_color() -> void:
	select_rect.color = Color(0.557, 1.0, 1.0, 0.3)
# ---- 框选节流 ----
func request_select_by_rect(rect: Rect2) -> void:
	_handle_optimized_select_builds(get_mouse_world_pos(), rect)
func reset_select_throttle() -> void:
	_last_mouse_pos_for_select = Vector2.ZERO
	_last_emit_select_rect = Rect2(0, 0, 0, 0)
	_pending_select_rect = Rect2(0, 0, 0, 0)
	if _select_throttle_timer != null and not _select_throttle_timer.is_stopped():
		_select_throttle_timer.stop()

func create_layer_system() -> SWLayerSystem:
	return SWHoldLayerSystem.new()

func _ready() -> void:
	sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.ByHold)
	sw_draw_manager_shadow.setDrawMode(SwDefine.GridDrawMode.HoldShadow)
	sw_draw_manager.useName = "Hold"
	sw_draw_manager_shadow.useName = "Shadow"
	select_rect.set_visible(false)
	# 初始化优化定时器
	_setup_select_optimization()
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	sw_draw_manager_shadow.on_view_rect_changed(viewRect,speedVec)
	super.on_view_rect_changed(viewRect,speedVec)


#region 优化相关函数
# 优化相关变量
var _select_throttle_timer: Timer = null
var _last_select_emit_time: int = 0
var _select_emit_interval: int = 100  # 毫秒
var _pending_select_rect: Rect2 = Rect2(0,0,0,0)
var _last_mouse_pos_for_select: Vector2 = Vector2.ZERO
var _select_distance_threshold: float = 15.0  # 像素
var _last_emit_select_rect: Rect2 = Rect2(0,0,0,0)
# 优化相关函数
func _setup_select_optimization() -> void:
	"""设置选择优化定时器"""
	if _select_throttle_timer == null:
		_select_throttle_timer = Timer.new()
		_select_throttle_timer.one_shot = true
		_select_throttle_timer.timeout.connect(_on_select_throttle_timeout)
		add_child(_select_throttle_timer)
	_select_throttle_timer.wait_time = _select_emit_interval / 1000.0
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
		if _select_throttle_timer != null:
			if not _select_throttle_timer.is_stopped():
				_select_throttle_timer.stop()
			_select_throttle_timer.start()
		_last_mouse_pos_for_select = mouse_pos
func _emit_select_builds_signal(rect: Rect2) -> void:
	"""发射选择构建信号，避免重复发射相同内容"""
	if _last_emit_select_rect != rect:
		selectBuildsByRect.emit(rect)
		_last_emit_select_rect = rect
# 优化参数调整函数
func set_select_emit_interval(interval_ms: int) -> void:
	"""动态调整选择发射间隔"""
	_select_emit_interval = interval_ms
	if _select_throttle_timer != null:
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
		"has_pending_emit": _pending_select_rect != Rect2(0,0,0,0)
	}
#endregion

# =========================================================
# 迁移期兼容：旧调用方改完后整块删除
# =========================================================

func isHoldEmpty() -> bool:
	var system := layer_system as SWHoldLayerSystem
	return system.is_hold_empty() if system != null else true
