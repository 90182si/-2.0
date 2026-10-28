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

func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	if rot == posmod(rotation+1,4) and pairId != -1:
		var pairBuild:SWBuildWireTunnel = swBuildManager.getBuildById(pairId) as SWBuildWireTunnel
		if pairBuild:
			var pos = pairBuild.buildAxisPos+SwDefine.dir_to_vec(rot)*SwDefine.GRID_SIZE
			return swBuildManager.getBuild(pos)
		return null
	var nextPos:Vector2i = buildAxisPos + 128*SwDefine.dir_to_vec(rot)
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	if nextBuild.bIsToBeRemoved():
		return null
	return nextBuild

#配对引脚（出口侧 rotation+1）是否朝向 dir 方向
#两根隧道必须引脚相对：A 的引脚在 DOWN，B 就得有引脚朝 UP 对着 A，B 的 rotation = A.rotation+2
func pinFaces(dir:int) -> bool:
	return posmod(rotation+1,4) == dir

func on_idled(swBuildManager:SWBuildManager) -> void:
	if pairId != -1:
		return
	var dir = posmod(rotation+1,4)
	var vec:Vector2i = SwDefine.dir_to_vec(dir)*SwDefine.GRID_SIZE
	for dis in SwDefine.MAX_TUNNEL_DIS+1:
		var pos = buildAxisPos+vec*(1+dis)
		var nextBuild:SWBuildWireTunnel = swBuildManager.getBuild(pos) as SWBuildWireTunnel
		if nextBuild == null or nextBuild.bIsToBeRemoved():
			continue
		if nextBuild.buildDefine.circuit_component_type != SwDefine.CircuitComponentType.WIRE_TUNNEL:
			continue
		#已经配上的不抢，否则会把对方原本的配对变成单向
		if nextBuild.pairId != -1:
			continue
		if not nextBuild.pinFaces(SwDefine.getAntiDir(dir)):
			continue
		pairId = nextBuild.id
		nextBuild.pairId = id
		return

func on_deleted(swBuildManager:SWBuildManager) -> void:
	if pairId == -1:
		return
	var nextBuild:SWBuildWireTunnel = swBuildManager.getBuildById(pairId)
	#自己这份一定要清掉，否则对方 id 失效时这个悬空 pairId 会一直留着
	pairId = -1
	if nextBuild:
		nextBuild.pairId = -1
