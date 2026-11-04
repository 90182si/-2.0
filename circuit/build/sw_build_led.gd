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
	# 亮灭已 shader 化：只写信号纹理帧槽选 on/off 帧，实例缓冲零写入。
	# drawRect 对帧建筑是死写入（烘焙走 _is_frame_build 分支不读它），去掉省两次组件查找 + 资源访问
	getRenderableCompoent().setFrameState(signalValue == SwDefine.CircuitSignal.HIGH)

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false
