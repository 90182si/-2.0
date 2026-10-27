class_name SWBuildCompoentCircuitNot extends SWBuildCompoentCircuit

# 非门组件
# 用 NotAndValues 组合输入表达式，求值后取反传播；reCalSignals 会级联下游电线。

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)

func getBuildExpr() -> void:
	#if _buildingExpr:
		#return
	#_buildingExpr = true
	var dir = SwDefine.getAntiDir(buildRef.rotation)
	var net:SWNet = pinNetMap.get(dir,null)
	if not net:
		#_buildingExpr = false
		return
	#该部件的函数是需要线与and
	if not pinExprMap.has(dir):
		pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		pinExprMap[dir].optFunc = SwCommon.NotAndValues
		pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
		#把每个条件加到args里面（穿越寄存器的反馈不判环）
		#appendDriverExprs(pinExprMap[dir], net)
		#把每个条件加到args里面
		var drivers = net.getDrivers()
		for driver:Dictionary in drivers:
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getCircuitCompoent().getBuildExpr()
			if build.getCircuitCompoent()._buildingExpr:
				build.in_loop = true
				buildRef.in_loop = true
				continue
			var expr = build.getCircuitCompoent().getExpr(pDir)
			if expr != null:
				pinExprMap[dir].args.append(expr)
		_buildingExpr = false

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	#如果这个端口是输出口，返回antiDir方向的表达式
	var antiDir = SwDefine.getAntiDir(pinDir)
	if portIsOutput(pinDir):
		return pinExprMap.get(antiDir,null)
	return null

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var value = super.getValue(dir)
	if value == SwDefine.CircuitSignal.HIGH:
		return SwDefine.CircuitSignal.LOW
	elif value == SwDefine.CircuitSignal.LOW:
		return SwDefine.CircuitSignal.HIGH
	return SwDefine.CircuitSignal.NONE

#非门只有一个输入口（参考坐标 DOWN，世界方向随旋转），输出取反
#求值与显示只读一次输入 net：输入电平就是贴图色，输出电平是它取反
func evaluate() -> int:
	var bit:int = netBit(SwDefine.getAntiDir(buildRef.rotation))
	buildRef.buildStateChanged(SwDefine.CircuitSignal.HIGH if bit == 1 else SwDefine.CircuitSignal.LOW)
	return 1 - bit

func evalOutput() -> int:
	return 1 - netBit(SwDefine.getAntiDir(buildRef.rotation))

func reCalSignals() -> void:
	evaluate()
