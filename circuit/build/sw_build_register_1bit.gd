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
	getRenderableCompoent().markAtlasRectDirty()

func save_state() -> Dictionary:
	var cir := getCircuitCompoent() as SWBuildCompoentCircuitRegister
	if cir == null:
		return {}
	#记录当前采样到的时钟电平：加载后 lastClk/curClk 都置为该值，
	#存档瞬间"已采样、未结算"的上升沿视为未发生，避免加载后拿未稳定的 D 多锁存一次
	return {"q": int(cir.qState), "clk": int(cir.curClk)}

func load_state(state: Dictionary) -> void:
	var cir := getCircuitCompoent() as SWBuildCompoentCircuitRegister
	if cir == null:
		return
	cir.qState = int(state.get("q", SwDefine.CircuitSignal.LOW)) as SwDefine.CircuitSignal
	#旧存档把时钟电平记在 cur_clk 下；两个键都读不到才退回 LOW（通常是时钟未接线）
	var clk := int(state.get("clk", state.get("cur_clk", SwDefine.CircuitSignal.LOW))) as SwDefine.CircuitSignal
	cir.curClk = clk
	cir.lastClk = clk
