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
	return btn.curSig

#输出电平只取决于时钟自身相位，与上游 net 无关
func evalOutput() -> int:
	var clk := buildRef as SWBuildClockSiggen
	return 1 if clk != null and clk.curSig == SwDefine.CircuitSignal.HIGH else 0

func evaluate() -> int:
	var clk := buildRef as SWBuildClockSiggen
	if clk == null:
		return 0
	buildRef.buildStateChanged(clk.curSig)
	return 1 if clk.curSig == SwDefine.CircuitSignal.HIGH else 0

func reCalSignals() -> void:
	evaluate()
