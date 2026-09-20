class_name SWBuildWireCom extends SWBuildItemDefine

func setPortFlag() -> void:
	pass
	
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
	
func getWireGroupBuilds(swBuildManager:SWBuildManager,wireBuild:SWBuildItemDefine,srcDir:SWDefine.SW_Dir) -> Array:
	var wireGroup:Array = []
	var visited:Dictionary[Vector2i,bool] = {}
	var wireBuildQueue:Array = [{"build":wireBuild,"dir":srcDir}]
	wireGroup.append({"build":wireBuild,"dir":srcDir})
	visited[wireBuild.buildAxisPos] = true
	while wireBuildQueue.size() > 0:
		var wireBuildItem = wireBuildQueue.pop_back()
		var wBuild = wireBuildItem["build"]
		var dir = wireBuildItem["dir"]
		var neiBuilds = wBuild.getBuildIOConnectBuildArr(swBuildManager)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			var neiDir = neiBuildItem["dir"]
			if not SwCommon.IsWireBuild(neiBuild):
				continue
			if wBuild is SWBuildWireCross:
				if neiDir != dir and neiDir != SWDefine.getAntiDir(dir):
					continue
			if visited.has(neiBuild.buildAxisPos):
				continue
			visited[neiBuild.buildAxisPos] = true
			
			wireBuildQueue.append({"build":neiBuild,"dir":neiDir})
			wireGroup.append({"build":neiBuild,"dir":neiDir})
	return wireGroup
	
func connectWireGroup(wireBuild:SWBuildItemDefine,swBuildManager:SWBuildManager) -> void:
	if wireBuild is SWBuildWire:
		var wireBuildwire = wireBuild as SWBuildWire
		if wireBuildwire.net:
			return
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,self,0)
		var wireNet:SWNet = SWNet.new()
		for wBuildItem:Dictionary in wireGroupBuilds:
			var wBuild = wBuildItem["build"]
			var dir = wBuildItem["dir"]
			wBuild.setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)
	elif wireBuild is SWBuildWireCross:
		var wireBuildwire = wireBuild as SWBuildWireCross
		if wireBuildwire.v_net == null:
			var wireGroupBuilds = getWireGroupBuilds(swBuildManager,self,0)
			var wireNet:SWNet = SWNet.new()
			for wBuildItem:Dictionary in wireGroupBuilds:
				var wBuild = wBuildItem["build"]
				var dir = wBuildItem["dir"]
				wBuild.setNet(wireNet,dir)
				wireNet.wireGroup.addWireBuild(wBuild)
		if wireBuildwire.h_net == null:
			var wireGroupBuilds = getWireGroupBuilds(swBuildManager,self,1)
			var wireNet:SWNet = SWNet.new()
			for wBuildItem:Dictionary in wireGroupBuilds:
				var wBuild = wBuildItem["build"]
				var dir = wBuildItem["dir"]
				wBuild.setNet(wireNet,dir)
				wireNet.wireGroup.addWireBuild(wBuild)
