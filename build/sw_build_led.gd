class_name SWBuildLed extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var retArr = []
	var linkBuilds = []
	for dir in range(4):
		if bLinkedPort(dir) or bIsToBeRemoved():
			continue
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,dir)
		if nextBuild == null:
			continue
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
		setLinkedPort(dir)
		nextBuild.setLinkedPort(antiDir)
		linkBuilds.append(nextBuild)
	retArr.append(linkBuilds)
	retArr.append({})
	return retArr
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + 128*SWDefine.dir_to_vec(rot)
	var dir:SWDefine.SW_Dir = rot
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
	var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
	if not nextBuild.isPort(v):
		return null
	if nextBuild.bLinkedPort(v):
		return null
	if nextBuild.isWireBuild():
		return nextBuild
	if nextBuild.portIsOutput(v):
		return nextBuild
	return null
	
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var linkedBuilds:Array[SWBuildItemDefine] = []
	for dir in range(4):
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,dir)
		if nextBuild == null:
			continue
		linkedBuilds.append(nextBuild)
	return linkedBuilds
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	canConBit = 0b1111
	portDefine = 0b0000
	portValue = 0b0000
