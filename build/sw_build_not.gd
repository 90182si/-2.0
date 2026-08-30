class_name SWBuildNot extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	#var dir:SWDefine.SW_Dir = rotation
	var retArr = []
	var linkBuilds = []
	var linkMap = {}
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(rotation)
	if not (bLinkedPort(rotation) or bIsToBeRemoved()):
		#return [[],{}]
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,rotation,false)
		if nextBuild:
			setLinkedPort(rotation)
			nextBuild.setLinkedPort(antiDir)
			linkBuilds.append(nextBuild)
			#linkMap[{"from":id,"dir":rotation,"name":buildDefine.buildName}] = {"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'!'}
			if nextBuild.comp_type != SWDefine.CircuitComponentType.WIRE:
				linkMap[{"from":id,"dir":rotation,"name":buildDefine.buildName}] = {"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'!'}
			else:
				linkMap[{"from":id,"dir":rotation,"name":buildDefine.buildName}] = {"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'!'}
		#return [[nextBuild],{{"from":id,"dir":rotation,"name":buildDefine.buildName}:{"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'!'}}]
	
	if not (bLinkedPort(antiDir) or bIsToBeRemoved()):
		var nextBuild2:SWBuildItemDefine = getDirBuild(swBuildManager,antiDir,true)
		if nextBuild2:
			linkBuilds.append(nextBuild2)
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir,isOutput:bool) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + 128*SWDefine.dir_to_vec(rot)
	#var dir:SWDefine.SW_Dir = rot
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(rot)
	var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
	if not nextBuild.isPort(v):
		return null
	if nextBuild.bLinkedPort(v):
		return null
	if nextBuild.isWireBuild():
		return nextBuild
	if not isOutput and nextBuild.portIsInput(v):
		return nextBuild
	if isOutput and nextBuild.portIsOutput(v):
		return nextBuild
	return null

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var retBuilds:Array[SWBuildItemDefine] = []
	var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,rotation,false)
	if nextBuild:
		retBuilds.append(nextBuild)
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(rotation)
	var nextBuilds:SWBuildItemDefine = getDirBuild(swBuildManager,antiDir,true)
	if nextBuilds:
		retBuilds.append(nextBuilds)
	return retBuilds
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	canConBit = 0b1010
	portDefine = 0b1000
	portValue = 0b1000
