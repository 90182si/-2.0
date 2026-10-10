class_name SWBuildCompoentCircuitTunnel extends SWBuildCompoentCircuit

var net:SWNet = null

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)
	
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)

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
			if pinIndex == 3:
				net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func setNet(srcNet:SWNet,dir:SwDefine.SW_Dir) -> void:
	var tunnelBuild:SWBuildWireTunnel = buildRef as SWBuildWireTunnel
	if tunnelBuild.pairId != -1:
		net = srcNet
		var circuitCom:SWBuildCompoentCircuitTunnel = tunnelBuild.getCircuitCompoent() as SWBuildCompoentCircuitTunnel
		circuitCom.net = srcNet

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [buildRef]
	
func getValue(_dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
	
func connectWireGroup(swBuildManager:SWBuildManager) -> void:
	#var wireBuildwire = buildRef as SWBuildWireCross
	#if v_net == null:
		#var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,0)
		#var wireNet:SWNet = SWNet.new()
		#for wBuildItem:Dictionary in wireGroupBuilds:
			#var wBuild = wBuildItem["build"]
			#var dir = wBuildItem["dir"]
			#wBuild.getCircuitCompoent().setNet(wireNet,dir)
			#wireNet.wireGroup.addWireBuild(wBuild)
	#if h_net == null:
		#var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,1)
		#var wireNet:SWNet = SWNet.new()
		#for wBuildItem:Dictionary in wireGroupBuilds:
			#var wBuild = wBuildItem["build"]
			#var dir = wBuildItem["dir"]
			#wBuild.getCircuitCompoent().setNet(wireNet,dir)
			#wireNet.wireGroup.addWireBuild(wBuild)
	pass
			
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(swBuildManager)
	
func resetPortState() -> void:
	super.resetPortState()
	setNet(null,0)
