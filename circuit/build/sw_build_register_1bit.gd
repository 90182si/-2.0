class_name SWBuildRegister1Bit extends SWBuildItemDefine

func _sub_init() -> void:
	getRenderableCompoent().buildAtlasRotable = false
	
# 1bit 寄存器使用专用组件承载时序逻辑（上升沿锁存 / Q 状态传播）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_REGISTER) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

# Q 输出状态驱动主体贴图亮灭
func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
	else:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
