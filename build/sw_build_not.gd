class_name SWBuildNot extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var retArr = []
	var linkBuilds = []
	var linkMap = {}
	if 1:
		var nextPos:Vector2i = buildAxisPos + SWDefine.dir_to_vec(rotation)*128
		var dir:SWDefine.SW_Dir = rotation
		if bPortCanCon(dir):
			var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
			if nextBuild:
				var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
				var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
				if nextBuild.canConBit&v > 0 and nextBuild.portDefine&v == 0:
					setPortCon(dir)
					linkedID[dir] = nextBuild.id
					nextBuild.linkedID[antiDir] = id
					linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'!'}
					linkBuilds.append(nextBuild)
	if 2:
		var nextPos:Vector2i = buildAxisPos + SWDefine.dir_to_vec((rotation+2)%4)*128
		var dir:SWDefine.SW_Dir = (rotation+2)%4
		if bPortCanCon(dir):
			var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
			if nextBuild:
				var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
				var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
				if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
					setPortCon(dir)
					linkedID[dir] = nextBuild.id
					nextBuild.linkedID[antiDir] = id
					#linkMap[{"from":nextBuild.id,"dir":antiDir,"name":nextBuild.buildName}]={"to":id,"name":buildDefine.buildName,"signal":'='}
					#linkBuilds.append(nextBuild)
					if nextBuild.portValue&v > 0 and (nextBuild.portDefine&v) > 0:
						portValue = 0b0010
						drawRect = buildDefine.atlasTextureOn.region
					else:
						portValue = 0b1000
						drawRect = buildDefine.atlasTextureOff.region
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var nextBuilds:Array[SWBuildItemDefine] = []
	if 1:
		var prePos:Vector2i = buildAxisPos + SWDefine.dir_to_vec(rotation)*128
		var dir:SWDefine.SW_Dir = rotation
		var preBuild:SWBuildItemDefine = swBuildManager.getBuild(prePos)
		if preBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<((3-antiDir+preBuild.rotation)%4)
			#下一个端口必须是输入口，输入口为0
			if (preBuild.canConBit&v) > 0:
				if (preBuild.portDefine&0b10000) == 0 and (preBuild.portDefine&v) == 0:
					nextBuilds.append(preBuild)
				elif (preBuild.portDefine&0b10000) > 0:
					nextBuilds.append(preBuild)
	if 2:
		var nextPos:Vector2i = buildAxisPos + SWDefine.dir_to_vec((rotation+2)%4)*128
		var dir:SWDefine.SW_Dir = (rotation+2)%4
		var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
		if nextBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
			#下一个端口必须是输出口，输入口为1
			if (nextBuild.canConBit&v) > 0:
				if (nextBuild.portDefine&0b10000) == 0 and (nextBuild.portDefine&v) > 0:
					nextBuilds.append(nextBuild)
				elif (nextBuild.portDefine&0b10000) > 0:
					nextBuilds.append(nextBuild)
	return nextBuilds
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	canConBit = 0b1010
	portDefine = 0b1000
	portValue = 0b1000
