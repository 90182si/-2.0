class_name SWBuildWireCross extends SWBuildItemDefine

var v_net:SWNet = null
var h_net:SWNet = null

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.RIGHT,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.LEFT,SWDefine.CircuitPinType.WIRE)
	pass

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [self]

func resetPortState(swBuildManager:SWBuildManager) -> void:
	super.resetPortState(swBuildManager)
	drawRect = buildDefine.atlasTextureOff.region
	v_net = null
	h_net = null

func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass

func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
	
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
