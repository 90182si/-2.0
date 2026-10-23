class_name SWMapLayer extends SWLayer

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.Tiling)
	sw_draw_manager.set_name("mapDrawManager")
	sw_draw_manager.useName = "Tiling"
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
