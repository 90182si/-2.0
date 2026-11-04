class_name SWBuildNot extends SWBuildItemDefine

#非门使用专用组件承载电路逻辑（表达式构建/取反求值/信号级联）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_NOT) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	# 帧切换已 shader 化：setFrameState 写信号纹理帧槽选 on/off 帧，实例缓冲零写入。
	# drawRect 对帧建筑是死写入（_bakeGeometry 走 _is_frame_build 分支直读 atlasTexture 帧，不读 drawRect），
	# 每拍非门刷新量极大（16x 计数器实测数千次），去掉省两次组件查找 + 资源 region 访问 + Rect2 拷贝
	getRenderableCompoent().setFrameState(signalValue == SwDefine.CircuitSignal.HIGH)
