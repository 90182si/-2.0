class_name SWBuildCompoentCircuitAnd extends SWBuildCompoentCircuit

# 与门组件
# 遍历各输入侧 net 的驱动表达式，用 AndValues 组合存到输出口，求值后传播。

func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	if pinExprMap.has(buildRef.rotation):
		_buildingExpr = false
		return
	var expr := SwDefine.SWCircuitStruct.new()
	expr.optFunc = SwCommon.AndValues
	expr.optFuncName = "SwCommon.AndValues"
	for dir in range(3,-1,-1):
		if not portIsInput(dir):
			continue
		var net:SWNet = pinNetMap.get(dir,null)
		if not net:
			continue
		for driver:Dictionary in net.getDrivers():
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getCircuitCompoent().getBuildExpr()
			if build.getCircuitCompoent()._buildingExpr:
				build.in_loop = true
				buildRef.in_loop = true
				continue
			var sub = build.getCircuitCompoent().getExpr(pDir)
			if sub:
				expr.args.append(sub)
	pinExprMap[buildRef.rotation] = expr
	_buildingExpr = false

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	if portIsOutput(pinDir):
		return pinExprMap.get(buildRef.rotation,null)
	return null

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var value = super.getValue(dir)
	var net = pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.getCircuitCompoent().setValue(dir,value)
	return value

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = [buildRef]
	buildRef.buildStateChanged(getValue(buildRef.rotation))
	return retArr
