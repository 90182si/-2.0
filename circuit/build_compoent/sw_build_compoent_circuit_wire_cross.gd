class_name SWBuildCompoentCircuitWireCross extends SWBuildCompoentCircuit

var v_net:SWNet = null
var h_net:SWNet = null

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.WIRE)
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)

func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	for driver:Dictionary in drivers:
		var dir = driver["pinDir"]
		if dir == 0 or dir == 2:
			v_net.setNet(drivers,loaders)
		if dir == 1 or dir == 3:
			h_net.setNet(drivers,loaders)
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	if buildRef.bIsToBeRemoved():
		return []
	for pinIndex:int in range(3,-1,-1):
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = buildRef.getDirBuild(swBuildManager,pinIndex)
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
			if pinIndex == 0 or pinIndex == 2:
				v_net.addLoader({"build":nextBuild,"pinDir":antiDir})
			if pinIndex == 1 or pinIndex == 3:
				h_net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func connectWireGroup(swBuildManager:SWBuildManager) -> void:
	var wireBuildwire = buildRef as SWBuildWireCross
	if v_net == null:
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,0)
		var wireNet:SWNet = SWNet.new()
		for wBuildItem:Dictionary in wireGroupBuilds:
			var wBuild = wBuildItem["build"]
			var dir = wBuildItem["dir"]
			wBuild.setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)
	if h_net == null:
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,1)
		var wireNet:SWNet = SWNet.new()
		for wBuildItem:Dictionary in wireGroupBuilds:
			var wBuild = wBuildItem["build"]
			var dir = wBuildItem["dir"]
			wBuild.setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)

#交叉电线不自行求值，视觉由传播时的 setValue 驱动；仅返回自身
func reCalSignals() -> Array[SWBuildItemDefine]:
	return [buildRef]

func getValue(_dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
