class_name SWMapLayer extends SWLayer
@onready var sw_render_node: SWRenderNode = $SWRenderNode

@onready var sw_draw_manager: SWDrawManager = $SWDrawManager
var _render_system:SWRenderSystem = null

var use_new_render_system:bool = false

func _ready() -> void:
	_render_system = sw_render_node._render_system
	#_render_system.setDrawMode(SwDefine.GridDrawMode.Tiling)
	if not use_new_render_system:
		sw_draw_manager.setDrawMode(SwDefine.GridDrawMode.Tiling)
		sw_draw_manager.set_name("mapDrawManager")
		sw_draw_manager.useName = "Tiling"
		sw_render_node.set_process_mode(ProcessMode.PROCESS_MODE_DISABLED)
	else:
		sw_render_node.setDrawMode(SwDefine.GridDrawMode.Tiling)
		sw_draw_manager.set_process_mode(ProcessMode.PROCESS_MODE_DISABLED)
	
func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	if not use_new_render_system:
		sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	else:
		sw_render_node.on_view_rect_changed(viewRect,speedVec)
