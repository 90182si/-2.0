class_name SWBuildButton extends SWBuildItemDefine

var pressed:bool = false

#按钮使用专用信号源组件承载电路逻辑
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_SOURCE) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

#按钮定义
func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCircuitCompoent()
	pressed = _pressed
	var renderable := getRenderableCompoent()
	var oldRect:Rect2 = renderable.drawRect
	if pressed == true:
		renderable.drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.HIGH)
	else:
		renderable.drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.LOW)
	#仅当主体贴图 region 真正切换时才失效渲染缓存，供点击路径按需重建几何层
	if renderable.drawRect != oldRect:
		markRenderPartsDirty()

func resetBuildState() -> void:
	in_loop = false
	getCircuitCompoent().resetPortState()
