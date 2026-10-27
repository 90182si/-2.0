class_name SWBuildClockSiggen extends SWBuildItemDefine

var pressed:bool = false
var curSig:SwDefine.CircuitSignal = SwDefine.CircuitSignal.LOW

#按钮使用专用信号源组件承载电路逻辑
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_CLOCK_SIGGEN) as SWBuildCompoentCircuitClockSiggen
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

#按钮定义
func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCircuitCompoent()
	if curSig == SwDefine.CircuitSignal.LOW:
		curSig = SwDefine.CircuitSignal.HIGH
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,curSig)
	else:
		curSig = SwDefine.CircuitSignal.LOW
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,curSig)

##按钮定义
#func onPressed(_pressed:bool) -> void:
	#var circuitCompoent := getCircuitCompoent()
	#pressed = _pressed
	#if pressed == true:
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
		#circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.HIGH)
	#else:
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
		#circuitCompoent.setPinValue(SwDefine.SW_Dir.UP,SwDefine.CircuitSignal.LOW)

func save_state() -> Dictionary:
	return {"pressed": pressed, "cur_sig": int(curSig)}

func load_state(state: Dictionary) -> void:
	pressed = state.get("pressed", false)
	curSig = int(state.get("cur_sig", SwDefine.CircuitSignal.LOW)) as SwDefine.CircuitSignal
	getCircuitCompoent().setPinValue(SwDefine.SW_Dir.UP, curSig)
