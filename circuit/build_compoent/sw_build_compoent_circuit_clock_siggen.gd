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
		pinExprMap[buildRef.rotation].op = SwDefine.CircuitOp.OP_PASS

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return pinExprMap.get(pinDir,null)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var btn := buildRef as SWBuildClockSiggen
	if btn == null:
		return SwDefine.CircuitSignal.NONE
	if dir != buildRef.rotation:
		return SwDefine.CircuitSignal.NONE
	var value = btn.curSig
	# T2.5：IR 模式下 net 写回与电线传播由 SWCircuitControl 的 push 阶段统一处理
	var control := SWCircuitControl.current
	if control != null and control.useIR:
		return value
	if portIsInput(dir):
		# 树路径保留副作用（注：时钟输出方向为 OUTPUT，此分支实际很少命中，维持既有行为）
		var net:SWNet = pinNetMap.get(dir,null)
		if net:
			net.curSignal = value
			for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
				load.getCircuitCompoent().setValue(dir,value)
	return value

## T2.5：时钟为状态驱动叶，IR 编译器生成 OP_READ 经此入口直读 curSig
func getPinReadState(dir:SwDefine.SW_Dir) -> int:
	if dir != buildRef.rotation:
		return -1
	var btn := buildRef as SWBuildClockSiggen
	if btn == null:
		return -1
	return 1 if btn.curSig == SwDefine.CircuitSignal.HIGH else 0

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = super.reCalSignals()
	buildRef.buildStateChanged(getValue(buildRef.rotation))
	return retArr
