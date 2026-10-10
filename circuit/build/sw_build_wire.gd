class_name SWBuildWire extends SWBuildWireCom

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
