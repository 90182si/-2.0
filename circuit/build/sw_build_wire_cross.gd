class_name SWBuildWireCross extends SWBuildWireCom

#var v_net:SWNet = null
#var h_net:SWNet = null

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false

func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
