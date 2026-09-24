class_name SWBuildLed extends SWBuildItemDefine

func rotOnce() -> void:
	pass

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.INPUT)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.INPUT)

func resetPortState() -> void:
	super.resetPortState()
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
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
		circuitCompoent.pinExprMap[dir] = SwDefine.SWCircuitStruct.new()
		circuitCompoent.pinExprMap[dir].optFunc = SwCommon.AndValues
		circuitCompoent.pinExprMap[dir].optFuncName = "SwCommon.AndValues"
		#把每个条件加到args里面
		#获取net的驱动端口们
		var drivers = net.getDrivers()
		for driver:Dictionary in drivers:
			var build = driver["build"]
			var pDir = driver["pinDir"]
			build.getBuildExpr()
			if build._buildingExpr:
				build.in_loop = true
				in_loop = true
				continue
			var expr = build.getExpr(pDir)
			if expr:
				circuitCompoent.pinExprMap[dir].args.append(expr)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var value = circuitCompoent.getValue(dir)
	var net = circuitCompoent.pinNetMap.get(dir,null)
	if net:
		for load:SWBuildItemDefine in net.wireGroup.wireBuilds:
			load.setValue(dir,value)
	return value

func reCalSignals() -> Array[SWBuildItemDefine]:
	var v1 = getValue(SwDefine.SW_Dir.UP) == SwDefine.CircuitSignal.HIGH
	var v2 = getValue(SwDefine.SW_Dir.RIGHT) == SwDefine.CircuitSignal.HIGH
	var v3 = getValue(SwDefine.SW_Dir.DOWN) == SwDefine.CircuitSignal.HIGH
	var v4 = getValue(SwDefine.SW_Dir.LEFT) == SwDefine.CircuitSignal.HIGH
	if v1 or v2 or v3 or v4:
		buildStateChanged(SwDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SwDefine.CircuitSignal.LOW)
	return [self]
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass
