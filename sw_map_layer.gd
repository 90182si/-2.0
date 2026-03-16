class_name SWMapLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.Tiling)
	pass

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	pass


func set_lod_far(is_far: bool) -> void:
	# 远景用低分辨率（4x4 合并），近景用高分辨率
	sw_draw_manager.set_lod_high(not is_far)
