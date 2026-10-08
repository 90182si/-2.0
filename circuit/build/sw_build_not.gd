class_name SWBuildNot extends SWBuildItemDefine

#非门使用专用组件承载电路逻辑（表达式构建/取反求值/信号级联）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_NOT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
