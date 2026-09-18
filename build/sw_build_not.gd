class_name SWBuildNot extends SWBuildItemDefine

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuit_compoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuit_compoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.OUTPUT)
	circuit_compoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.INPUT)
	pass

func resetPortState(swBuildManager:SWBuildManager) -> void:
	super.resetPortState(swBuildManager)
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuit_compoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#如果这个端口是输入口，并且电路组件里的pinNet存在这个方向的net
	var antiDir = SWDefine.getAntiDir(pinDir)
	if portIsOutput(pinDir):
		return circuit_compoent.pinExprMap.get(antiDir,null)
	return null

func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	var circuit_compoent : SWBuildCompoentCircuit = getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var dir = SWDefine.getAntiDir(rotation)
	var net:SWNet = circuit_compoent.pinNetMap.get(dir,null)
	if not net:
		_buildingExpr = false
		return
	#获取net的驱动端口们
	var drivers = net.getDrivers()
	#该部件的函数是需要线与and
	if circuit_compoent.pinExprMap.has(dir):
		_buildingExpr = false
		return
	circuit_compoent.pinExprMap[dir] = SWDefine.SWCircuitStruct.new()
	circuit_compoent.pinExprMap[dir].optFunc = SwCommon.NotAndValues
	circuit_compoent.pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
	#把每个条件加到args里面
	for driver:Dictionary in drivers:
		var build = driver["build"]
		var pDir = driver["pinDir"]
		build.getBuildExpr()
		var expr = build.getExpr(pDir)
		if expr != null:
			circuit_compoent.pinExprMap[dir].args.append(expr)
	_buildingExpr = false
	
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var value = circuitCompoent.getValue(dir)
	var wireValue = SWDefine.CircuitSignal.NONE
	if value == SWDefine.CircuitSignal.HIGH:
		wireValue = SWDefine.CircuitSignal.LOW
	elif value == SWDefine.CircuitSignal.LOW:
		wireValue = SWDefine.CircuitSignal.HIGH
	var net = circuitCompoent.pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir,wireValue)
	return wireValue

func reCalSignals() -> Array[SWBuildItemDefine]:
	var downDir = SWDefine.getAntiDir(rotation)
	buildStateChanged(getValue(downDir))
	return [self]
	
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass
