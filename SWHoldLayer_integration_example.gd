# 集成示例 - 如何在现有SWHoldLayer中添加优化

# 在您的SWHoldLayer.gd文件中添加这些变量和函数：

# 添加的变量：
# var _throttle_timer: Timer
# var _last_emit_time: int = 0
# var _emit_interval: int = 100
# var _pending_rect: Rect2 = null
# var _last_mouse_pos: Vector2 = Vector2.ZERO
# var _distance_threshold: float = 15.0
# var _last_emit_rect: Rect2 = null

# 在_ready()函数中添加：
# func _ready() -> void:
#     _setup_optimization()
#     # 您现有的初始化代码...

# 添加的函数：
func _setup_optimization() -> void:
    _throttle_timer = Timer.new()
    _throttle_timer.wait_time = _emit_interval / 1000.0
    _throttle_timer.one_shot = true
    _throttle_timer.timeout.connect(_on_throttle_timeout)
    add_child(_throttle_timer)

func _on_throttle_timeout() -> void:
    if _pending_rect != null:
        _emit_selection_signal(_pending_rect)
        _pending_rect = null
        _last_emit_time = Time.get_ticks_msec()

func _emit_selection_signal(rect: Rect2) -> void:
    """发射选择信号，避免重复发射"""
    if _last_emit_rect == null or _last_emit_rect != rect:
        emit_signal("selectBuildsByRect", rect)
        _last_emit_rect = rect

# 修改您的鼠标移动处理函数，假设原函数是：
# func _on_mouse_moved(event: InputEventMouseMotion) -> void:
#     var rect = calculate_selection_rect(event.position)
#     emit_signal("selectBuildsByRect", rect)

# 修改为：
func _on_mouse_moved_optimized(event: InputEventMouseMotion) -> void:
    var rect = calculate_selection_rect(event.position)
    _handle_mouse_movement_optimized(event.position, rect)

func _handle_mouse_movement_optimized(mouse_pos: Vector2, current_rect: Rect2) -> void:
    """优化的鼠标移动处理"""
    # 检查距离阈值
    if _last_mouse_pos != Vector2.ZERO:
        var distance = _last_mouse_pos.distance_to(mouse_pos)
        if distance < _distance_threshold:
            return  # 距离太近，忽略
    
    # 检查时间节流
    var current_time = Time.get_ticks_msec()
    if current_time - _last_emit_time >= _emit_interval:
        _emit_selection_signal(current_rect)
        _last_mouse_pos = mouse_pos
        _last_emit_time = current_time
    else:
        # 保存到待处理队列
        _pending_rect = current_rect
        if not _throttle_timer.is_stopped():
            _throttle_timer.stop()
        _throttle_timer.start()
        _last_mouse_pos = mouse_pos