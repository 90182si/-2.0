class_name SWBuildWireTunnel extends SWBuildItemDefine


func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuitCompoent := getCircuitCompoent()
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)

func onPressed(_pressed:bool) -> void:
	var circuitCompoent := getCircuitCompoent()

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	var circuitCompoent := getCircuitCompoent()
	return circuitCompoent.pinExprMap.get(pinDir,null)

func getBuildExpr() -> void:
	var circuitCompoent := getCircuitCompoent()
	if not circuitCompoent.pinExprMap.has(rotation):
		circuitCompoent.pinExprMap[rotation] = SwDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[rotation].optFunc = SwCommon.EqualValues
		circuitCompoent.pinExprMap[rotation].optFuncName = "SwCommon.EqualValues"
		circuitCompoent.pinExprMap[rotation].args = [SwDefine.SWBuildPinStruct.new(self,rotation)]


func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
