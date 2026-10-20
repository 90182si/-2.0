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
		pinExprMap[buildRef.rotation].op = SwDefine.CircuitOp.OP_PASS

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return pinExprMap.get(pinDir,null)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var btn := buildRef as SWBuildButton
	if btn == null:
		return SwDefine.CircuitSignal.NONE
	if dir != buildRef.rotation:
		return SwDefine.CircuitSignal.NONE
	var value = SwDefine.CircuitSignal.HIGH if btn.pressed else SwDefine.CircuitSignal.LOW
	# T2.5：IR 模式下 net 写回与电线传播由 SWCircuitControl 的 push 阶段统一处理
	var control := SWCircuitControl.current
	if control != null and control.useIR:
		return value
	#树路径：信号源主动刷新输出 net 的 curSignal，并向下游电线传播（浮空输出时也能刷新）
	var net:SWNet = pinNetMap.get(buildRef.rotation, null)
	if net:
		net.curSignal = value
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(buildRef.rotation, value)
	return value

## T2.5：按钮/开关为状态驱动叶，IR 编译器生成 OP_READ 经此入口直读 pressed
func getPinReadState(dir:SwDefine.SW_Dir) -> int:
	if dir != buildRef.rotation:
		return -1
	var btn := buildRef as SWBuildButton
	if btn == null:
		return -1
	return 1 if btn.pressed else 0

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = super.reCalSignals()
	#var btn := buildRef as SWBuildButton
	#var value = SwDefine.CircuitSignal.HIGH if btn.pressed else SwDefine.CircuitSignal.LOW
	return retArr
