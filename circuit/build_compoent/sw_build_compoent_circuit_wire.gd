class_name SWBuildCompoentCircuitWire extends SWBuildCompoentCircuit

var net:SWNet = null

func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)
		
func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var nextBuild:SWBuildItemDefine = buildRef.getDirBuild(swBuildManager,rot)
	if not nextBuild:
		return null
	var nextCircuitCom = nextBuild.getCircuitCompoent()
	if not nextCircuitCom:
		return null
	var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(rot)
	if not nextCircuitCom.isPort(antiDir):
		return null
	if SwCommon.IsWireBuild(buildRef) or SwCommon.IsWireBuild(nextBuild):
		return nextBuild
	if portIsOutput(rot) and nextCircuitCom.portIsInput(antiDir):
		return nextBuild
	if portIsInput(rot) and nextCircuitCom.portIsOutput(antiDir):
		return nextBuild
	return null

func getNet(swBuildManager:SWBuildManager) -> Array:
	if buildRef.bIsToBeRemoved():
		return []
	for pinIndex:int in range(3,-1,-1):
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild == null:
			continue
		var nextBuildCircuitCom:SWBuildCompoentCircuit = nextBuild.getCircuitCompoent()
		if nextBuildCircuitCom == null:
			continue
		var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		if SwCommon.IsWireBuild(nextBuild):
			continue
		if nextBuildCircuitCom.portIsInput(antiDir):
			setLinkedPort(pinIndex)
			nextBuildCircuitCom.setLinkedPort(antiDir)
			net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func connectWireGroup(swBuildManager:SWBuildManager) -> void:
	if net == null:
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,0)
		var wireNet:SWNet = SWNet.new()
		for wBuildItem:Dictionary in wireGroupBuilds:
			var wBuild = wBuildItem["build"]
			var dir = wBuildItem["dir"]
			wBuild.setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)
