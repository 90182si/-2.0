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

func getStateData() -> Dictionary:
	return {"cur_sig": int(curSig)}

## 时钟相位也是元件状态：onPressed 是「翻转」不是「设定」，
## 不恢复 curSig 的话加载后第一拍会整拍错开，计数器跟着跳错
func restoreStateData(data: Dictionary) -> void:
	if data.is_empty():
		return
	var sig:SwDefine.CircuitSignal = int(data.get("cur_sig", SwDefine.CircuitSignal.LOW))
	curSig = sig
	getCircuitCompoent().setPinValue(SwDefine.SW_Dir.UP, curSig)
