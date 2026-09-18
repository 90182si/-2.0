class_name SWBuildButton extends SWBuildItemDefine

var pressed:bool = false

#按钮定义
func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.OUTPUT)

func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	pressed = _pressed
	if pressed == true:
		drawRect = buildDefine.atlasTextureOn.region
		circuitCompoent.setPinValue(SWDefine.SW_Dir.UP,SWDefine.CircuitSignal.HIGH)
	else:
		drawRect = buildDefine.atlasTextureOff.region
		circuitCompoent.setPinValue(SWDefine.SW_Dir.UP,SWDefine.CircuitSignal.LOW)

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.pinExprMap.get(pinDir,null)

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	if not circuitCompoent.pinExprMap.has(rotation):
		circuitCompoent.pinExprMap[rotation] = SWDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[rotation].optFunc = SWCommon.EqualValues
		circuitCompoent.pinExprMap[rotation].optFuncName = "SWCommon.EqualValues"
		circuitCompoent.pinExprMap[rotation].args = [SWDefine.SWBuildPinStruct.new(self,rotation)]


func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	if dir != rotation:
		return SWDefine.CircuitSignal.NONE
	return SWDefine.CircuitSignal.HIGH if pressed else SWDefine.CircuitSignal.LOW
