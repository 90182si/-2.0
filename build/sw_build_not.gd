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
				var v:int = 1<<(3-antiDir+nextBuild.rotation)
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
				var v:int = 1<<(3-antiDir+nextBuild.rotation)
				if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
					setPortCon(dir)
					linkedID[dir] = nextBuild.id
					nextBuild.linkedID[antiDir] = id
					linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}
					linkBuilds.append(nextBuild)
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var nextBuilds:Array[SWBuildItemDefine] = []
	if 1:
		var nextPos:Vector2i = buildAxisPos + SWDefine.dir_to_vec(rotation)*128
		var dir:SWDefine.SW_Dir = rotation
		var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
		if nextBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<(3-antiDir+nextBuild.rotation)
			#下一个端口必须是输入口，输入口为0
			if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine|v) == 0:
				nextBuilds.append(nextBuild)
	if 2:
		var nextPos:Vector2i = buildAxisPos + SWDefine.dir_to_vec((rotation+2)%4)*128
		var dir:SWDefine.SW_Dir = (rotation+2)%4
		var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
		if nextBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<(3-antiDir+nextBuild.rotation)
			#下一个端口必须是输出口，输入口为1
			if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
				nextBuilds.append(nextBuild)
	return nextBuilds
	
func buildStateChanged() -> void:
	drawRect = buildDefine.atlasTextureOff.region

func setPortFlag() -> void:
	canConBit = 0b1010
	portDefine = 0b1000
