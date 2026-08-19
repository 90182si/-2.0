class_name SWBuildLed extends SWBuildItemDefine

func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array:
	var retArr = []
	var linkBuilds = []
	var linkMap = {}
	for dir in range(4):
		if not bPortCanCon(dir):
			continue
		var vec:Vector2i = SWDefine.dir_to_vec(dir)*128
		var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(buildAxisPos+vec)
		if nextBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<(3-antiDir+nextBuild.rotation)
			#下一个端口必须是输出口，输入口为1
			if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
				setPortCon(dir)
				linkedID[dir] = nextBuild.id
				nextBuild.setPortCon(antiDir)
				nextBuild.linkedID[antiDir] = id
				#{{"from":id,"dir":dir}:{"to":nextBuild.id}}
				linkMap[{"from":nextBuild.id,"dir":antiDir,"name":nextBuild.buildDefine.buildName}]={"to":id,"name":buildDefine.buildName,"signal":'='}
				linkBuilds.append(nextBuild)
	retArr.append(linkBuilds)
	retArr.append(linkMap)
	return retArr

func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var linkedBuilds:Array[SWBuildItemDefine] = []
	for dir in range(4):
		var vec:Vector2i = SWDefine.dir_to_vec(dir)*128
		var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(buildAxisPos+vec)
		if nextBuild:
			var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(dir)
			var v:int = 1<<(3-antiDir+nextBuild.rotation)
			#下一个端口必须是输出口，输入口为1
			if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
				linkedBuilds.append(nextBuild)
	return linkedBuilds
	
func buildStateChanged() -> void:
	drawRect = buildDefine.atlasTextureOff.region

func setPortFlag() -> void:
	canConBit = 0b1111
	portDefine = 0b0000
