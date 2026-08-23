class_name SWBuildWire extends SWBuildItemDefine

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
			var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
			#下一个端口必须是输入口，输入口为1
			if (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) == 0:
				setPortCon(dir)
				linkedID[dir] = nextBuild.id
				nextBuild.setPortCon(antiDir)
				nextBuild.linkedID[antiDir] = id
				#{{"from":id,"dir":dir}:{"to":nextBuild.id}}
				linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}
				linkBuilds.append(nextBuild)
				#if nextBuild.portValue&v > 0:
					#portValue = 1<<(3-dir)
					#drawRect = buildDefine.atlasTextureOn.region
				#else:
					#portValue = 0b0000
					#drawRect = buildDefine.atlasTextureOff.region
			elif (nextBuild.canConBit&v) > 0 and (nextBuild.portDefine&v) > 0:
				#setPortCon(dir)
				#linkedID[dir] = nextBuild.id
				#nextBuild.setPortCon(antiDir)
				#nextBuild.linkedID[antiDir] = id
				#{{"from":id,"dir":dir}:{"to":nextBuild.id}}
				#linkMap[{"from":id,"dir":dir,"name":buildDefine.buildName}]={"to":nextBuild.id,"name":nextBuild.buildDefine.buildName,"signal":'='}
				linkBuilds.append(nextBuild)
				if nextBuild.portValue&v > 0:
					portValue = 1<<(3-dir)
					drawRect = buildDefine.atlasTextureOn.region
				else:
					portValue = 0b0000
					drawRect = buildDefine.atlasTextureOff.region
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
			var v:int = 1<<((3-antiDir+nextBuild.rotation)%4)
			if (nextBuild.canConBit&v) > 0:
				linkedBuilds.append(nextBuild)
	return linkedBuilds
	
func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	canConBit = 0b1111
	portDefine = 0b10000
	portValue = 0b0000
