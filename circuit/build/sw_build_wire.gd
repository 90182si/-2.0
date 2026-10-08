class_name SWBuildWire extends SWBuildWireCom

#var net:SWNet = null
var lowColor:Color
var highColor:Color

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = false
	renderable.buildHasBase = false
	if buildDefine.buildName == "电线A":
		lowColor = Color(0.071, 0.269, 0.362, 1.0)
		highColor = Color(0.338, 0.713, 0.896, 1.0)
	elif buildDefine.buildName == "电线B":
		lowColor = Color(0.462, 0.034, 0.198, 1.0)
		highColor = Color(0.99, 0.57, 0.657, 1.0)
	
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
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOff.region
		pass
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		#getRenderableCompoent().drawRect = buildDefine.atlasTextureOn.region
		pass
