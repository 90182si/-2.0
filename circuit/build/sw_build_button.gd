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
	if pressed == true:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.HIGH)
	else:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.LOW)
	getRenderableCompoent().markAtlasRectDirty()

func resetBuildState() -> void:
	in_loop = false
	getCircuitCompoent().resetPortState()
	getRenderableCompoent().markRenderPartsDirty()

func save_state() -> Dictionary:
	return {"pressed": pressed}

func load_state(state: Dictionary) -> void:
	var p: bool = state.get("pressed", false)
	if p != pressed:
		onPressed(p)
