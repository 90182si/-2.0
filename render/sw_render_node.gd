class_name SWRenderNode extends Node
#被控UI
#画面展示
#信号接收

#每帧只推脏标记
#临时：放置、删除
var _render_system:SWRenderSystem = null

func _init() -> void:
	add_to_group("SWRender")
	
func _ready() -> void:
	pass # Replace with function body.

func create_render_system() -> SWRenderSystem:
	_render_system = SWRenderSystem.new()
	return _render_system

func load_chunk_data() -> void:
	pass

#没有放置和删除，只有状态改变，现实和隐藏
func on_view_rect_changed(viewRect:Rect2 = get_viewport().get_visible_rect(),speedVec:Vector2 = Vector2.ZERO) -> void:
	_render_system.set_view_rect(viewRect)
	pass
	
func setDrawMode(drawMode:SwDefine.GridDrawMode) -> void:
	_render_system.setDrawMode(drawMode)
	
func draw(data) -> void:
	pass

func update_frame(delte:float) -> void:
	#_render_system.get_dirty_data()
	pass
