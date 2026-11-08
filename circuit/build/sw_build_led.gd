class_name SWBuildLed extends SWBuildItemDefine

#灯泡使用专用组件承载电路逻辑（表达式构建/求值/信号重算）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_LED) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func rotOnce() -> void:
	pass

# 当前亮灭（现场推导）= 任一输入 net 为高。
# GPU LED resolve 下亮灭由 compute shader 算进信号纹理，CPU 不再遍历灯泡，
# 所以 signal_state 可能滞后；低频调用方（存档/探针/测试）用这个取准确值。
func currentSignal() -> SwDefine.CircuitSignal:
	var comp := getCircuitCompoent() as SWBuildCompoentCircuitLed
	if comp == null:
		return signal_state as SwDefine.CircuitSignal
	for dir in 4:
		var net: SWNet = comp.pinNetMap.get(dir, null)
		if net != null and net.curSignal == SwDefine.CircuitSignal.HIGH:
			return SwDefine.CircuitSignal.HIGH
	return SwDefine.CircuitSignal.LOW

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	# 亮灭已 shader 化：只写信号纹理帧槽选 on/off 帧，实例缓冲零写入。
	# drawRect 对帧建筑是死写入（烘焙走 _is_frame_build 分支不读它），去掉省两次组件查找 + 资源访问
	getRenderableCompoent().setFrameState(signalValue == SwDefine.CircuitSignal.HIGH)

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
