class_name SWBuildWireCross extends SWBuildWireCom

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false

func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent
