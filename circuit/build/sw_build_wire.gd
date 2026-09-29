class_name SWBuildWire extends SWBuildWireCom

#var net:SWNet = null

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = false
	renderable.buildHasBase = false
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var build = super.getDirBuild(swBuildManager,rot)
	if build is SWBuildWire:
		var wireBuild = build as SWBuildWire
		if wireBuild.buildDefine.buildName != buildDefine.buildName:
			return null
	return build
	
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE) as SWBuildCompoentCircuit
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent
	
func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region

func setPortFlag(buildDef:SWBuildDefine) -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)
	pass

func setNet(srcNet:SWNet,dir:SwDefine.SW_Dir) -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE) as SWBuildCompoentCircuit
	circuitCompoent.net = srcNet
	for pinIndex in range(3,-1,-1):
		circuitCompoent.pinNetMap[pinIndex] = srcNet

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [self]

func resetPortState() -> void:
	super.resetPortState()
	getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
	setNet(null,0)
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE) as SWBuildCompoentCircuit
	circuitCompoent.connectWireGroup(swBuildManager)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
