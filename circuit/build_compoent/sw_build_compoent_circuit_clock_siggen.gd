class_name SWBuildCompoentCircuitClockSiggen extends SWBuildCompoentCircuit

var pressed:bool = false

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)

func getBuildExpr() -> void:
	if not pinExprMap.has(buildRef.rotation):
		pinExprMap[buildRef.rotation] = SwDefine.SWCircuitStruct.new()
		pinExprMap[buildRef.rotation].optFunc = SwCommon.EqualValues
		pinExprMap[buildRef.rotation].optFuncName = "SwCommon.EqualValues"
		pinExprMap[buildRef.rotation].args = [SwDefine.SWBuildPinStruct.new(buildRef,buildRef.rotation)]

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return pinExprMap.get(pinDir,null)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var btn := buildRef as SWBuildClockSiggen
	if btn == null:
		return SwDefine.CircuitSignal.NONE
	if dir != buildRef.rotation:
		return SwDefine.CircuitSignal.NONE
	#return SwDefine.CircuitSignal.HIGH if btn.pressed else SwDefine.CircuitSignal.LOW
	return btn.curSig
