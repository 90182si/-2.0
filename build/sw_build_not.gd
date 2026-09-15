class_name SWBuildNot extends SWBuildItemDefine

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.OUTPUT)
	#circuitCompoent.setPinDefine(SWDefine.SW_Dir.RIGHT,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.INPUT)
	#circuitCompoent.setPinDefine(SWDefine.SW_Dir.LEFT,SWDefine.CircuitPinType.WIRE)
	pass

func resetPortCon() -> void:
	super.resetPortCon()
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#如果这个端口是输入口，并且电路组件里的pinNet存在这个方向的net
	var antiDir = SWDefine.getAntiDir(pinDir)
	if portIsOutput(pinDir) and circuitCompoent.pinNetMap.has(antiDir):
		#var net:SWNet = circuitCompoent.pinNetMap[antiDir]
		#if not net:
			#return circuitCompoent.pinExprMap[antiDir]
		##获取net的驱动端口们
		#var drivers = net.getDrivers()
		##该部件的函数是需要线与and
		#circuitCompoent.pinExprMap[antiDir].optFunc = SwCommon.AndValues
		##把每个条件加到args里面
		#for driver:Dictionary in drivers:
			#var build = driver["build"]
			#var pDir = driver["pinDir"]
			#circuitCompoent.pinExprMap[antiDir].args.append(build.getExpr(pDir))
		return circuitCompoent.pinExprMap[antiDir]
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
				circuitCompoent.pinExprMap[dir].optFunc = SwCommon.NotValues
				circuitCompoent.pinExprMap[dir].optFuncName = "SwCommon.NotValues"
				#把每个条件加到args里面
				for driver:Dictionary in drivers:
					var build = driver["build"]
					var pDir = driver["pinDir"]
					circuitCompoent.pinExprMap[dir].args.append(build.getExpr(pDir))
			else:
				pass
	
func getValue(swBuildManager:SWBuildManager,dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
