class_name SWBuildNot extends SWBuildItemDefine

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region

func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuit_compoent := getCircuitCompoent()
	circuit_compoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.OUTPUT)
	circuit_compoent.setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)
	pass

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	var circuit_compoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#如果这个端口是输入口，并且电路组件里的pinNet存在这个方向的net
	var antiDir = SwDefine.getAntiDir(pinDir)
	if circuit_compoent.portIsOutput(pinDir):
		return circuit_compoent.pinExprMap.get(antiDir,null)
	return null

func getBuildExpr() -> void:
	if _buildingExpr:
		return
	_buildingExpr = true
	var circuit_compoent : SWBuildCompoentCircuit = getCircuitCompoent()
	var dir = SwDefine.getAntiDir(rotation)
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
	circuit_compoent.pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
	circuit_compoent.pinExprMap[dir].optFunc = SwCommon.NotAndValues
	circuit_compoent.pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
	#把每个条件加到args里面
	for driver:Dictionary in drivers:
		var build = driver["build"]
		var pDir = driver["pinDir"]
		build.getBuildExpr()
		if build._buildingExpr:
			build.in_loop = true
			in_loop = true
			continue
		var expr = build.getExpr(pDir)
		if expr != null:
			circuit_compoent.pinExprMap[dir].args.append(expr)
	_buildingExpr = false
	
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var circuitCompoent := getCircuitCompoent()
	var value = circuitCompoent.getValue(dir)
	var wireValue = SwDefine.CircuitSignal.NONE
	if value == SwDefine.CircuitSignal.HIGH:
		wireValue = SwDefine.CircuitSignal.LOW
	elif value == SwDefine.CircuitSignal.LOW:
		wireValue = SwDefine.CircuitSignal.HIGH
	var net = circuitCompoent.pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir,wireValue)
	return wireValue

func reCalSignals() -> Array[SWBuildItemDefine]:
	var retArr:Array[SWBuildItemDefine] = [self]
	var downDir = SwDefine.getAntiDir(rotation)
	buildStateChanged(getValue(downDir))
	var circuitCompoent := getCircuitCompoent()
	var net = circuitCompoent.pinNetMap.get(downDir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			retArr.append(load)
	return retArr
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass
