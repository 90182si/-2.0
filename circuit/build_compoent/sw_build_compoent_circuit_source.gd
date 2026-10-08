class_name SWBuildCompoentCircuitSource extends SWBuildCompoentCircuit

# 信号源组件（按钮/开关共用）
# 负责构建 EqualValues 表达式，并直接依据 buildRef 的按下状态输出信号。

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
	var btn := buildRef as SWBuildButton
	if btn == null:
		return SwDefine.CircuitSignal.NONE
	if dir != buildRef.rotation:
		return SwDefine.CircuitSignal.NONE
	return SwDefine.CircuitSignal.HIGH if btn.pressed else SwDefine.CircuitSignal.LOW
