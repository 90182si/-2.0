class_name SWBuildButton extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var dir:SWDefine.SW_Dir = rotation
	if bLinkedPort(dir):
		return [[],{}]
	var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,rotation)
	if nextBuild == null:
		return [[],{}]
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
	setLinkedPort(dir)
	nextBuild.setLinkedPort(antiDir)
	return [[nextBuild],{{"from":id,"dir":dir,"name":buildDefine.buildName}:{"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}}]
	
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
	if nextBuild.portIsInput(v):
		return nextBuild
	return null
	
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,rotation)
	if nextBuild:
		return [nextBuild]
	return []

func setPortFlag() -> void:
	canConBit = 0b1000
	portDefine = 0b1000
	portValue = 0b0000

var pressed:bool = false
func onPressed(_pressed:bool) -> void:
	pressed = _pressed
	if pressed == true:
		drawRect = buildDefine.atlasTextureOn.region
		portValue = 0b1000
		if circuit:
			circuit.inputValues[id] = portValue
	else:
		drawRect = buildDefine.atlasTextureOff.region
		portValue = 0b0000
		if circuit:
			circuit.inputValues[id] = portValue
