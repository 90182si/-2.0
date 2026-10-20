class_name SWBuildNot extends SWBuildItemDefine

#非门使用专用组件承载电路逻辑（表达式构建/取反求值/信号级联）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_NOT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	var renderable := getRenderableCompoent()
	var oldRect:Rect2 = renderable.drawRect
	if signalValue == SwDefine.CircuitSignal.LOW:
		renderable.drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		renderable.drawRect = buildDefine.atlasTextureOn.region
	#仅当主体贴图 region 真正切换时失效渲染缓存（R3.2：只覆写主体 part）
	if renderable.drawRect != oldRect:
		markBodyRectDirty()
