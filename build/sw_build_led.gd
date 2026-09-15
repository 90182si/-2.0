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

func resetPortCon() -> void:
	super.resetPortCon()
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	# var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	# #如果这个端口是输入口(led必然是) 并且电路组件里的pinNet存在这个方向的net
	# if portIsInput(pinDir) and circuitCompoent.pinNetMap.has(pinDir):
	# 	var net:SWNet = circuitCompoent.pinNetMap[pinDir]
	# 	if not net:
	# 		return circuitCompoent.pinExprMap
	# 	#获取net的驱动端口们
	# 	var drivers = net.getDrivers()
	# 	#该部件的函数是需要线与and
	# 	circuitCompoent.pinExprMap.optFunc = SwCommon.AndValues
	# 	#把每个条件加到args里面
	# 	for driver:Dictionary in drivers:
	# 		var build = driver["build"]
	# 		var pDir = driver["pinDir"]
	# 		circuitCompoent.pinExprMap.args.append(build.getExpr(pDir))
	# return circuitCompoent.pinExprMap
	return null

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	for dir in range(3,-1,-1):
		if portIsInput(dir) and circuitCompoent.pinNetMap.has(dir):
			var net:SWNet = circuitCompoent.pinNetMap[dir]
			if not net:
				continue 
			#获取net的驱动端口们
			var drivers = net.getDrivers()
			#该部件的函数是需要线与and
			if not circuitCompoent.pinExprMap.has(dir):
				circuitCompoent.pinExprMap[dir] = SWDefine.SWCircuitStruct.new()
				circuitCompoent.pinExprMap[dir].optFunc = SwCommon.AndValues
				circuitCompoent.pinExprMap[dir].optFuncName = "SwCommon.AndValues"
				#把每个条件加到args里面
				for driver:Dictionary in drivers:
					var build = driver["build"]
					var pDir = driver["pinDir"]
					circuitCompoent.pinExprMap[dir].args.append(build.getExpr(pDir))
			else:
				pass

func getValue(swBuildManager:SWBuildManager,dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.getValue(swBuildManager,dir)

func reCalSignals(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var v1 = getValue(swBuildManager,SWDefine.SW_Dir.UP) == SWDefine.CircuitSignal.HIGH
	var v2 = getValue(swBuildManager,SWDefine.SW_Dir.RIGHT) == SWDefine.CircuitSignal.HIGH
	var v3 = getValue(swBuildManager,SWDefine.SW_Dir.DOWN) == SWDefine.CircuitSignal.HIGH
	var v4 = getValue(swBuildManager,SWDefine.SW_Dir.LEFT) == SWDefine.CircuitSignal.HIGH
	if v1 or v2 or v3 or v4:
		buildStateChanged(SWDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SWDefine.CircuitSignal.LOW)
	return [self]
