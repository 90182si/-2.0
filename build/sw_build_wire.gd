class_name SWBuildWire extends SWBuildItemDefine

var wireGroup:SWDefine.SWWireGroup = null

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	#canConBit = 0b1111
	#portDefine = 0b10000
	#portValue = 0b0000
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.OUTPUT)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.INPUT)
	pass

func reCalSignals(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []

func resetPortCon() -> void:
	super.resetPortCon()
	drawRect = buildDefine.atlasTextureOff.region
	wireGroup = null

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	#由于电线会是driver，所以这个函数不会被调用
	if not circuitCompoent.pinExprMap.has(pinDir):
		circuitCompoent.pinExprMap[pinDir] = SWDefine.SWCircuitStruct.new()
	assert("你是不是搞错了！！！")
	return circuitCompoent.pinExprMap[pinDir]

func getBuildExpr() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	assert("你是不是搞错了！！！")

func getValue(swBuildManager:SWBuildManager,dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
