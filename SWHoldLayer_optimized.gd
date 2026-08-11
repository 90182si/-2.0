# SWHoldLayer.gd - 鼠标移动节流优化版本
extends Node2D

signal selectBuildsByRect(rect: Rect2)

@onready var _throttle_timer: Timer = Timer.new()
var _last_emit_time: int = 0
var _emit_interval: int = 100  # 毫秒，可以根据需要调整
var _pending_rect: Rect2 = null

func _ready() -> void:
    # 设置节流定时器
    _throttle_timer.wait_time = _emit_interval / 1000.0
    _throttle_timer.one_shot = true
    _throttle_timer.timeout.connect(_on_throttle_timeout)
    add_child(_throttle_timer)

func _on_throttle_timeout() -> void:
    if _pending_rect != null:
        emit_signal("selectBuildsByRect", _pending_rect)
        _pending_rect = null
        _last_emit_time = Time.get_ticks_msec()

func handle_mouse_movement(mouse_rect: Rect2) -> void:
    """处理鼠标移动，使用节流机制"""
    var current_time = Time.get_ticks_msec()
    
    if current_time - _last_emit_time >= _emit_interval:
        # 立即发射信号
        emit_signal("selectBuildsByRect", mouse_rect)
        _last_emit_time = current_time
    else:
        # 保存到待处理队列，定时器会处理
        _pending_rect = mouse_rect
        if not _throttle_timer.is_stopped():
            _throttle_timer.stop()
        _throttle_timer.start()

# 如果是原有的鼠标事件处理函数
func _process(delta: float) -> void:
    # 或者在这里处理鼠标移动
    pass

func _input(event: InputEvent) -> void:
    # 如果使用输入事件处理
    pass