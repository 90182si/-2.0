class_name SWBuildCompoentCircuitNot extends SWBuildCompoentCircuit

# 非门组件
# 用 NotAndValues 组合输入表达式，求值后取反传播；reCalSignals 会级联下游电线。

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)

func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	var dir = SwDefine.getAntiDir(buildRef.rotation)
	var net:SWNet = pinNetMap.get(dir,null)
	if not net:
		_buildingExpr = false
		return
	#该部件的函数是需要线与and
	if not pinExprMap.has(dir):
		pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		pinExprMap[dir].optFunc = SwCommon.NotAndValues
		pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
		#把每个条件加到args里面（穿越寄存器的反馈不判环）
		appendDriverExprs(pinExprMap[dir], net)
		pinExprMap[dir].op = SwDefine.CircuitOp.OP_NAND
	_buildingExpr = false

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	#如果这个端口是输出口，返回antiDir方向的表达式
	var antiDir = SwDefine.getAntiDir(pinDir)
	if portIsOutput(pinDir):
		return pinExprMap.get(antiDir,null)
	return null

func getValue(_dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	#表达式挂在输入方向键上，基类通过 NAND 已算出取反结果，不可二次取反
	var inDir = SwDefine.getAntiDir(buildRef.rotation)
	var value = super.getValue(inDir)
	#rotation 为输出方向，结果写入输出侧 net 并向下游电线传播
	var net:SWNet = pinNetMap.get(buildRef.rotation,null)
	if net:
		net.curSignal = value
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(buildRef.rotation,value)
	return value

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = super.reCalSignals()
	#buildStateChanged 使用输出方向的值（getValue 返回的就是 NOT 输出）
	buildRef.buildStateChanged(getValue(buildRef.rotation))
	return retArr
