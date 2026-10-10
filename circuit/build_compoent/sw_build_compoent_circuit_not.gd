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
	#获取net的驱动端口们
	var drivers = net.getDrivers()
	#该部件的函数是需要线与and
	if pinExprMap.has(dir):
		_buildingExpr = false
		return
	pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
	pinExprMap[dir].optFunc = SwCommon.NotAndValues
	pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
	#把每个条件加到args里面
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
	var wireValue = SwDefine.CircuitSignal.NONE
	if value == SwDefine.CircuitSignal.HIGH:
		wireValue = SwDefine.CircuitSignal.LOW
	elif value == SwDefine.CircuitSignal.LOW:
		wireValue = SwDefine.CircuitSignal.HIGH
	var net = pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(dir,wireValue)
	return wireValue

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = [buildRef]
	var downDir = SwDefine.getAntiDir(buildRef.rotation)
	var value = getValue(downDir)
	buildRef.buildStateChanged(value)
	var net:SWNet = pinNetMap.get(downDir,null)
	if net:
		net.curSignal = value
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			retArr.append(load)
	return retArr
