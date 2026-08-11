# SWHoldLayer.gd - 组合优化版本（推荐）
extends Node2D

signal selectBuildsByRect(rect: Rect2)

@onready var _throttle_timer: Timer = Timer.new()
var _last_emit_time: int = 0
var _emit_interval: int = 100  # 毫秒
var _pending_rect: Rect2 = null
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _distance_threshold: float = 15.0  # 像素
var _last_emit_rect: Rect2 = null

func _ready() -> void:
    _setup_throttle_timer()

func _setup_throttle_timer() -> void:
    _throttle_timer.wait_time = _emit_interval / 1000.0
    _throttle_timer.one_shot = true
    _throttle_timer.timeout.connect(_on_throttle_timeout)
    add_child(_throttle_timer)

func _on_throttle_timeout() -> void:
    if _pending_rect != null:
        _emit_selection(_pending_rect)
        _pending_rect = null
        _last_emit_time = Time.get_ticks_msec()

func handle_mouse_movement_optimized(mouse_pos: Vector2, current_rect: Rect2) -> void:
    """优化的鼠标移动处理"""
    # 检查距离阈值
    if _last_mouse_pos != Vector2.ZERO:
        var distance = _last_mouse_pos.distance_to(mouse_pos)
        if distance < _distance_threshold:
            return  # 距离太近，忽略
    
    # 检查时间节流
    var current_time = Time.get_ticks_msec()
    if current_time - _last_emit_time >= _emit_interval:
        _emit_selection(current_rect)
        _last_mouse_pos = mouse_pos
        _last_emit_time = current_time
    else:
        # 保存到待处理队列
        _pending_rect = current_rect
        if not _throttle_timer.is_stopped():
            _throttle_timer.stop()
        _throttle_timer.start()
        _last_mouse_pos = mouse_pos

func _emit_selection(rect: Rect2) -> void:
    """发射选择信号，避免重复发射相同内容"""
    if _last_emit_rect == null or _last_emit_rect != rect:
        emit_signal("selectBuildsByRect", rect)
        _last_emit_rect = rect

# 调试和性能监控函数
func set_emit_interval(interval_ms: int) -> void:
    """动态调整发射间隔"""
    _emit_interval = interval_ms
    _throttle_timer.wait_time = interval_ms / 1000.0

func set_distance_threshold(threshold: float) -> void:
    """动态调整距离阈值"""
    _distance_threshold = threshold

func get_performance_stats() -> Dictionary:
    """获取性能统计信息"""
    return {
        "emit_interval": _emit_interval,
        "distance_threshold": _distance_threshold,
        "last_emit_time_ago": Time.get_ticks_msec() - _last_emit_time,
        "has_pending_emit": _pending_rect != null
    }