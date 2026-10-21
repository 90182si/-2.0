class_name SWBuildRegister1Bit extends SWBuildItemDefine

func _sub_init() -> void:
	getRenderableCompoent().buildAtlasRotable = false
	
# 1bit 寄存器使用专用组件承载时序逻辑（上升沿锁存 / Q 状态传播）
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_REGISTER) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func getStateData() -> Dictionary:
	var comp := getCircuitCompoent() as SWBuildCompoentCircuitRegister
	if comp == null:
		return {}
	return {"q": int(comp.qState), "last_clk": int(comp.lastClk),
		"cur_clk": int(comp.curClk), "cur_d": int(comp.curD)}

## 恢复锁存值与沿检测历史：只存 qState 不够，
## lastClk/curClk 一丢，加载后第一次采样要么漏沿要么误锁存一拍
func restoreStateData(data: Dictionary) -> void:
	if data.is_empty():
		return
	var comp := getCircuitCompoent() as SWBuildCompoentCircuitRegister
	if comp == null:
		return
	comp.qState = int(data.get("q", SwDefine.CircuitSignal.LOW))
	comp.lastClk = int(data.get("last_clk", SwDefine.CircuitSignal.LOW))
	comp.curClk = int(data.get("cur_clk", SwDefine.CircuitSignal.NONE))
	comp.curD = int(data.get("cur_d", SwDefine.CircuitSignal.NONE))
	# 贴图与 signal_state 要跟 Q 一致，否则加载瞬间显示的是默认（灭）图
	buildStateChanged(comp.qState)

# Q 输出状态驱动主体贴图亮灭
func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	var renderable := getRenderableCompoent()
	var oldRect:Rect2 = renderable.drawRect
	if signalValue == SwDefine.CircuitSignal.HIGH:
		renderable.drawRect = buildDefine.atlasTextureOn.region
	else:
		renderable.drawRect = buildDefine.atlasTextureOff.region
	#仅当主体贴图 region 真正切换时失效渲染缓存（R3.2：只覆写主体 part）
	if renderable.drawRect != oldRect:
		markBodyRectDirty()
