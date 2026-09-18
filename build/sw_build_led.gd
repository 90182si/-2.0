class_name SWBuildLed extends SWBuildItemDefine



func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.RIGHT,SWDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.LEFT,SWDefine.CircuitPinType.INPUT)

func resetPortState(swBuildManager:SWBuildManager) -> void:
	super.resetPortState(swBuildManager)
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	for dir in range(3,-1,-1):
		#如果已经存在了就不计算
		if circuitCompoent.pinExprMap.has(dir):
			continue
		#如果不是输入口
		if not portIsInput(dir):
			continue
		var net:SWNet = circuitCompoent.pinNetMap.get(dir,null)
		if not net:
			continue 
		#该部件的函数是需要线与and
		circuitCompoent.pinExprMap[dir] = SWDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[dir].optFunc = SwCommon.AndValues
		circuitCompoent.pinExprMap[dir].optFuncName = "SwCommon.AndValues"
		#把每个条件加到args里面
		#获取net的驱动端口们
		var drivers = net.getDrivers()
		for driver:Dictionary in drivers:
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getBuildExpr()
			var expr = build.getExpr(pDir)
			if expr:
				circuitCompoent.pinExprMap[dir].args.append(expr)

func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var value = circuitCompoent.getValue(dir)
	var net = circuitCompoent.pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir,value)
	return value

func reCalSignals() -> Array[SWBuildItemDefine]:
	var v1 = getValue(SWDefine.SW_Dir.UP) == SWDefine.CircuitSignal.HIGH
	var v2 = getValue(SWDefine.SW_Dir.RIGHT) == SWDefine.CircuitSignal.HIGH
	var v3 = getValue(SWDefine.SW_Dir.DOWN) == SWDefine.CircuitSignal.HIGH
	var v4 = getValue(SWDefine.SW_Dir.LEFT) == SWDefine.CircuitSignal.HIGH
	if v1 or v2 or v3 or v4:
		buildStateChanged(SWDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SWDefine.CircuitSignal.LOW)
	return [self]
	
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass
