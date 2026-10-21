class_name SWBuildCompoentCircuitWire extends SWBuildCompoentCircuit

var net:SWNet = null

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)

func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)
		
#func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	#var nextBuild:SWBuildItemDefine = buildRef.getDirBuild(swBuildManager,rot)
	#if not nextBuild:
		#return null
	#var nextCircuitCom = nextBuild.getCircuitCompoent()
	#if not nextCircuitCom:
		#return null
	#var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(rot)
	#if not nextCircuitCom.isPort(antiDir):
		#return null
	#if SwCommon.IsWireBuild(buildRef) or SwCommon.IsWireBuild(nextBuild):
		#return nextBuild
	#if portIsOutput(rot) and nextCircuitCom.portIsInput(antiDir):
		#return nextBuild
	#if portIsInput(rot) and nextCircuitCom.portIsOutput(antiDir):
		#return nextBuild
	#return null

func getNet(swBuildManager:SWBuildManager) -> Array:
	if buildRef.bIsToBeRemoved():
		return []
	# 邻接表按求值轮缓存：find1/initPortState 已为本轮每个建筑查过一遍四方向，
	# 这里复用同一份，省掉每根电线再查 4 次空间网格（大存档加载 nets+ids 阶段的主要开销）
	var control := SWCircuitControl.current
	var neighbors: Array = control.getNeighborsCached(buildRef) if control != null else getBuildIOConnectBuildArr(swBuildManager)
	for neiItem:Dictionary in neighbors:
		var pinIndex:int = int(neiItem["dir"])
		var nextBuild:SWBuildItemDefine = neiItem["build"]
		#如果这个方向的端口已经被占用
		if isLinkedPort(pinIndex):
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
			wBuild.getCircuitCompoent().setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)

#电线不自行求值，视觉由 signalTex 按 netId 上色驱动；仅返回自身
func reCalSignals() -> Array[SWBuildItemDefine]:
	return [buildRef]

func getValue(_dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE

func setNet(srcNet:SWNet,dir:SwDefine.SW_Dir) -> void:
	net = srcNet
	if srcNet:
		net.wireGroup.wireName = buildRef.buildDefine.buildName
	for pinIndex in range(3,-1,-1):
		pinNetMap[pinIndex] = srcNet
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildRef.buildStateChanged(value)
	pass

## R4.1：电线电平即所在 net 的电平（未连网时视为无信号）
func getWireLevel() -> int:
	return int(net.curSignal) if net != null else SwDefine.CircuitSignal.NONE

func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(swBuildManager)

func resetPortState() -> void:
	super.resetPortState()
	setNet(null,0)
