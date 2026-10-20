class_name SWBuildLed extends SWBuildItemDefine

#灯泡使用专用组件承载电路逻辑（表达式构建/求值/信号重算）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_LED) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func rotOnce() -> void:
	pass

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	var renderable := getRenderableCompoent()
	var oldRect:Rect2 = renderable.drawRect
	if signalValue == SwDefine.CircuitSignal.LOW:
		renderable.drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		renderable.drawRect = buildDefine.atlasTextureOn.region
	#仅当主体贴图 region 真正切换时才失效渲染缓存，避免每次信号重算都触发几何层重建
	if renderable.drawRect != oldRect:
		markRenderPartsDirty()

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
