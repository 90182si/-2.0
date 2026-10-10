class_name SWBuildWireTunnel extends SWBuildItemDefine

var pairId:int = -1

func _sub_init() -> void:
	var renderable = getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
	renderable.buildHasAtlas = true
	renderable.buildHasBase = true
	
func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT_WIRE_TUNNEL) as SWBuildCompoentCircuitTunnel
		_circuitCompoent.setBuildRef(self)
	return _circuitCompoent

#func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	#if rot == posmod(rotation+1,4) and pairId != -1:
		#var pairBuild:SWBuildWireTunnel = swBuildManager.getBuildById(pairId) as SWBuildWireTunnel
		#if pairBuild:
			##return pairBuild.getDirBuild(swBuildManager,rot)
			#return 
		#return null
	#var nextPos:Vector2i = buildAxisPos + 128*SwDefine.dir_to_vec(rot)
	#var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	#if nextBuild == null:
		#return null
	#if nextBuild.bIsToBeRemoved():
		#return null
	#return nextBuild

func on_idled(swBuildManager:SWBuildManager) -> void:
	if pairId != -1:
		return
	var dir = posmod(rotation+1,4)
	var vec:Vector2i = SwDefine.dir_to_vec(dir)*SwDefine.GRID_SIZE
	for dis in SwDefine.MAX_TUNNEL_DIS+1:
		var pos = buildAxisPos+vec*(1+dis)
		var nextBuild:SWBuildWireTunnel = swBuildManager.getBuild(pos) as SWBuildWireTunnel
		if nextBuild and nextBuild.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE_TUNNEL:
			pairId = nextBuild.id
			nextBuild.pairId = id
			return

func on_deleted(swBuildManager:SWBuildManager) -> void:
	if pairId == -1:
		return
	var nextBuild:SWBuildWireTunnel = swBuildManager.getBuildById(pairId)
	if nextBuild:
		pairId = -1
		nextBuild.pairId = -1
		
