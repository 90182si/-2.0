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
	#circuit_compoent.setPinDefine(SWDefine.SW_Dir.RIGHT,SWDefine.CircuitPinType.WIRE)
	circuit_compoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.INPUT)
	#circuit_compoent.setPinDefine(SWDefine.SW_Dir.LEFT,SWDefine.CircuitPinType.WIRE)
	pass

func resetPortState() -> void:
	super.resetPortState()
	drawRect = buildDefine.atlasTextureOff.region

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuit_compoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#如果这个端口是输入口，并且电路组件里的pinNet存在这个方向的net
	var antiDir = SWDefine.getAntiDir(pinDir)
	if portIsOutput(pinDir) and circuit_compoent.pinNetMap.has(antiDir) and circuit_compoent.pinExprMap.has(antiDir):
		return circuit_compoent.pinExprMap[antiDir]
	return null

func getBuildExpr() -> void:
	var circuit_compoent : SWBuildCompoentCircuit = getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	for dir in range(3,-1,-1):
		if portIsInput(dir) and circuit_compoent.pinNetMap.has(dir):
			var net:SWNet = circuit_compoent.pinNetMap[dir]
			if not net:
				continue 
			#获取net的驱动端口们
			var drivers = net.getDrivers()
			#该部件的函数是需要线与and
			if not circuit_compoent.pinExprMap.has(dir):
				circuit_compoent.pinExprMap[dir] = SWDefine.SWCircuitStruct.new()
				circuit_compoent.pinExprMap[dir].optFunc = SwCommon.NotAndValues
				circuit_compoent.pinExprMap[dir].optFuncName = "SwCommon.NotAndValues"
				#把每个条件加到args里面
				for driver:Dictionary in drivers:
					var build = driver["build"]
					var pDir = driver["pinDir"]
					var expr = build.getExpr(pDir)
					if expr != null:
						circuit_compoent.pinExprMap[dir].args.append(expr)
			else:
				pass
	
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.getValue(dir)

func reCalSignals(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#var v1 = getValue(SWDefine.SW_Dir.UP) == SWDefine.CircuitSignal.HIGH
	#var v2 = getValue(SWDefine.SW_Dir.RIGHT) == SWDefine.CircuitSignal.HIGH
	var downDir = SWDefine.getAntiDir(rotation)
	var v3 = getValue(downDir) == SWDefine.CircuitSignal.HIGH
	#var v4 = getValue(SWDefine.SW_Dir.LEFT) == SWDefine.CircuitSignal.HIGH
	var loads = []
	if circuitCompoent.pinNetMap.has(downDir):
		loads = circuitCompoent.pinNetMap[downDir].wireGroup.wireBuilds
	if not v3:
		buildStateChanged(SWDefine.CircuitSignal.HIGH)
		for load in loads:
			load.setValue(downDir,SWDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SWDefine.CircuitSignal.LOW)
		for load in loads:
			load.setValue(downDir,SWDefine.CircuitSignal.LOW)
		
	
	return [self]
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass
