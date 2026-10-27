class_name SWRenderSystem extends SWSystem
#组织数据
var _render_node:SWRenderNode = null
var _drawMode:SwDefine.GridDrawMode = SwDefine.GridDrawMode.ByContent

func _init() -> void:
	system_name = &"core.render"
	run_order = SwDefine.ORDER_RENDER
	receives_frame = true

func frame(_delta:float) -> void:
	_render_node.update_frame(_delta)
	pass

func attach_render_node(node:SWRenderNode) -> void:
	_render_node = node
	node._render_system = self 

func setDrawMode(drawMode:SwDefine.GridDrawMode) -> void:
	_drawMode = drawMode

func set_view_rect(viewRect:Rect2) -> void:
	#根据viewRect标记脏数据
	pass
