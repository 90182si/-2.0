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
			tool_selected.emit(define))
		hudLayer.save_requested.connect(func():
			self.save_requested.emit())
		hudLayer.load_requested.connect(func():
			self.load_requested.emit())
