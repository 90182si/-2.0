class_name SWBuildWireCross extends SWBuildWireCom

#var v_net:SWNet = null
#var h_net:SWNet = null

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = false

func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region

func setNet(srcNet:SWNet,dir:SwDefine.SW_Dir) -> void:
	#net = srcNet
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
	if dir == 0 or dir == 2:
		circuitCompoent.v_net = srcNet
		circuitCompoent.pinNetMap[0] = circuitCompoent.v_net
		circuitCompoent.pinNetMap[2] = circuitCompoent.v_net
	elif dir == 1 or dir == 3:
		circuitCompoent.h_net = srcNet
		circuitCompoent.pinNetMap[1] = circuitCompoent.h_net
		circuitCompoent.pinNetMap[3] = circuitCompoent.h_net

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
	circuitCompoent.v_net = null
	circuitCompoent.h_net = null
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS) as SWBuildCompoentCircuit
	circuitCompoent.connectWireGroup(swBuildManager)

func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
