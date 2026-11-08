class_name SWHudLayerSystem extends SWLayerSystem

signal tool_selected(build_define:SWBuildDefine)
signal save_requested()
signal load_requested()

func _init() -> void:
	system_name = &"core.layer.hud"
	run_order = SwDefine.ORDER_LAYER_HUD
	
func attach_view(v:SWLayer) -> void:
	super.attach_view(v)
	var hudLayer := v as SWHudLayer
	if hudLayer:
		hudLayer.selTool.connect(func(define:SWBuildDefine):
			if enable:
				tool_selected.emit(define))
		hudLayer.save_requested.connect(func():
			if enable:
				self.save_requested.emit())
		hudLayer.load_requested.connect(func():
			if enable:
				self.load_requested.emit())

#悬浮元件变了：把它的表达式推给右上角面板（build 为 null 就收起来）
func on_hover_build_changed(build:SWBuildItemDefine) -> void:
	var hudLayer := view as SWHudLayer
	if hudLayer == null or not enable:
		return
	hudLayer.show_build_expr(build)

#「建筑信息」开关同时控制右上角表达式面板的显隐
func set_expr_enabled(enabled:bool) -> void:
	var hudLayer := view as SWHudLayer
	if hudLayer == null:
		return
	hudLayer.set_expr_enabled(enabled)
