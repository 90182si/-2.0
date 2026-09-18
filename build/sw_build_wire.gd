class_name SWBuildWire extends SWBuildItemDefine

var net:SWNet = null

func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir) -> SWBuildItemDefine:
	var build = super.getDirBuild(swBuildManager,rot)
	if build is SWBuildWire:
		var wireBuild = build as SWBuildWire
		if wireBuild.buildDefine.buildName != buildDefine.buildName:
			return null
	return build

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SWDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SWDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.UP,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.RIGHT,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.DOWN,SWDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SWDefine.SW_Dir.LEFT,SWDefine.CircuitPinType.WIRE)
	pass

func getWireGroupBuilds(swBuildManager:SWBuildManager,wireBuild:SWBuildWire) -> Array[SWBuildWire]:
	var wireGroup:Array[SWBuildWire] = []
	var wireBuildQueue:Array[SWBuildWire] = [wireBuild]
	var visited:Dictionary[Vector2i,bool] = {}
	
	visited[wireBuild.buildAxisPos] = true
	wireGroup.append(wireBuild)
	while wireBuildQueue.size() > 0:
		var wBuild:SWBuildWire = wireBuildQueue.pop_back()
		var neiBuilds = wBuild.getBuildIOConnectBuildArr(swBuildManager)
		for neiBuildItem:Dictionary in neiBuilds:
			var neiBuild = neiBuildItem["build"]
			if not SWCommon.IsWireBuild(neiBuild):
				continue
			var neiWireBuild = neiBuild as SWBuildWire
			if neiWireBuild.buildDefine.buildName != wBuild.buildDefine.buildName:
				continue
			if visited.has(neiBuild.buildAxisPos):
				continue
			visited[neiBuild.buildAxisPos] = true
			wireBuildQueue.append(neiBuild)
			wireGroup.append(neiBuild)
	return wireGroup
	
func connectWireGroup(swBuildManager:SWBuildManager) -> void:
	if net:
		return
	var wireBuildQueue:Dictionary[SWBuildWire,bool] = {}
	wireBuildQueue[self] = true
	#从wireBuilds中获取与build相连的wire
	while wireBuildQueue.size() > 0:
		var wireBuild = wireBuildQueue.keys().back()
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,wireBuild)
		var wireNet:SWNet = SWNet.new()
		#从wireBuildQueue中删除wireGroup
		for wBuild:SWBuildWire in wireGroupBuilds:
			wireBuildQueue.erase(wBuild)
			wireNet.addWireBuild(wBuild)
			
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	for pinIndex:int in range(3,-1,-1):
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#这里的portIsInput(pinIndex)会导致wire所有端口跳过，wire连接的下一个输入口没法被获取到
		if bIsToBeRemoved():
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild == null:
			continue
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		if SWCommon.IsWireBuild(nextBuild):
			continue
		if nextBuild.portIsInput(antiDir):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [self]

func resetPortState(swBuildManager:SWBuildManager) -> void:
	super.resetPortState(swBuildManager)
	drawRect = buildDefine.atlasTextureOff.region
	net = null
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(swBuildManager)

func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
	
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
