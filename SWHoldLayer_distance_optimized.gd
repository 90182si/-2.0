# SWHoldLayer.gd - 距离阈值优化版本
extends Node2D

signal selectBuildsByRect(rect: Rect2)

var _last_mouse_pos: Vector2 = Vector2.ZERO
var _distance_threshold: float = 10.0  # 像素，可以根据需要调整
var _last_emit_rect: Rect2 = null

func handle_mouse_movement(mouse_pos: Vector2, current_rect: Rect2) -> void:
    """处理鼠标移动，使用距离阈值"""
    if _last_mouse_pos == Vector2.ZERO:
        # 第一次移动，直接发射
        _emit_selection(current_rect)
        _last_mouse_pos = mouse_pos
        return
    
    var distance = _last_mouse_pos.distance_to(mouse_pos)
    
    if distance >= _distance_threshold:
        _emit_selection(current_rect)
        _last_mouse_pos = mouse_pos
    # 否则忽略这次移动

func _emit_selection(rect: Rect2) -> void:
    """发射选择信号"""
    if _last_emit_rect == null or _last_emit_rect != rect:
        emit_signal("selectBuildsByRect", rect)
        _last_emit_rect = rect