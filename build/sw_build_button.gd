class_name SWBuildButton extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var nextPos:Vector2i = buildAxisPos + Vector2i(0,-1)*128
	var dir:SWDefine.SW_Dir = SWDefine.SW_Dir.UP
	match rotation:
		0:
			pass
		1:
			nextPos = buildAxisPos + Vector2i(1,0)*128
			dir = SWDefine.SW_Dir.RIGHT
			pass
		2:
			nextPos = buildAxisPos + Vector2i(0,1)*128
			dir = SWDefine.SW_Dir.DOWN
			pass
		3:
			nextPos = buildAxisPos + Vector2i(-1,0)*128
			dir = SWDefine.SW_Dir.LEFT
			pass
		_:
			pass
	if not bPortCanCon(dir):
		return [[],{}]
	var retArr = []
	var linkBuilds = []
	var linkMap = {}
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild:
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
		var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
		#下一个端口必须是输入口，输入口为0
		if (nextBuild.canConBit&v) > 0:
			if ((nextBuild.portDefine&0b10000) == 0 and (nextBuild.portDefine&v) == 0) or (nextBuild.portDefine&0b10000) > 0:
				setPortCon(dir)
				linkedID[dir] = nextBuild.id
				nextBuild.setPortCon(antiDir)
				nextBuild.linkedID[antiDir] = id
				linkMap = {{"from":id,"dir":dir,"name":buildDefine.buildName}:{"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}}
				linkBuilds.append(nextBuild)
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var nextPos:Vector2i = buildAxisPos + Vector2i(0,-1)*128
	var dir:SWDefine.SW_Dir = SWDefine.SW_Dir.UP
	match rotation:
		0:
			pass
		1:
			nextPos = buildAxisPos + Vector2i(1,0)*128
			dir = SWDefine.SW_Dir.RIGHT
			pass
		2:
			nextPos = buildAxisPos + Vector2i(0,1)*128
			dir = SWDefine.SW_Dir.DOWN
			pass
		3:
			nextPos = buildAxisPos + Vector2i(-1,0)*128
			dir = SWDefine.SW_Dir.LEFT
			pass
		_:
			pass
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild:
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
		var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
		#下一个端口必须是输入口，输入口为0
		if (nextBuild.canConBit&v) > 0:
			if (nextBuild.portDefine&0b10000) == 0 and (nextBuild.portDefine&v) > 0:
				return [nextBuild]
			elif (nextBuild.portDefine&0b10000) > 0:
				return [nextBuild]
		#if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine|v) == 0:
			#return [nextBuild]
	return []
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	pass

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
			circuit.signalValues[id] = 1
	else:
		drawRect = buildDefine.atlasTextureOff.region
		portValue = 0b0000
		if circuit:
			circuit.signalValues[id] = 0
