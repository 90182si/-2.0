class_name SWBuildCompoentCircuitTunnel extends SWBuildCompoentCircuit

var net:SWNet = null

func setPortFlag(_buildDef:SWBuildDefine) -> void:
	setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)
	
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)
	
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array:
	var linkedBuilds:Array = []
	var pinIndex = posmod(buildRef.rotation+3,4)
	var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
	if nextBuild:
		linkedBuilds.append({"build":nextBuild,"dir":pinIndex})
	pinIndex = posmod(buildRef.rotation+1,4)
	nextBuild = getDirBuild(swBuildManager,pinIndex)
	if nextBuild:
		linkedBuilds.append({"build":nextBuild,"dir":pinIndex})
	return linkedBuilds
	
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
			if pinIndex == SwDefine.getAntiDir(posmod(buildRef.rotation-1,4)):
				net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func setNet(srcNet:SWNet,_dir:SwDefine.SW_Dir) -> void:
	net = srcNet
	#隧道是等电位导线：两个物理口（入口 rotation+3 / 出口 rotation+1）必须指向同一根 net。
	#原先只按传入的 dir 写一个口，而 dir 是 BFS 的「从上一个建筑看本建筑」方向，
	#可能根本不是物理口方向（比如从正上方扫进来），那样两个口一个都没设上。
	#又因为先放的隧道会把自己建过 net 的口留在旧 net 上，配对/连线换 net 后新旧两根共存，
	#接在未更新那一口的负载就恒读空 net（表现为不亮）。
	#配对隧道那一端不在这里同步：setNet 拿不到 buildManager；
	#connectWireGroup 会把配对隧道也放进 wireGroup 遍历，那边会再调一次本函数
	assign_both_pins(srcNet)

#两个物理口一起写：只写单口会让隧道「一半通一半断」，且断的那一半事后没有任何地方会补上
func assign_both_pins(srcNet:SWNet) -> void:
	pinNetMap[posmod(buildRef.rotation+3,4)] = srcNet
	pinNetMap[posmod(buildRef.rotation+1,4)] = srcNet
	invalidateDirMasks()

func getValue(_dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
	
func connectWireGroup(swBuildManager:SWBuildManager) -> void:
	if net == null:
		var wireGroupBuilds = getWireGroupBuilds(swBuildManager,buildRef,posmod(buildRef.rotation+1,4))
		var tunnelBuild:SWBuildWireTunnel = buildRef as SWBuildWireTunnel
		if tunnelBuild.pairId != -1:
			var pairTunnel:SWBuildWireTunnel = swBuildManager.getBuildById(tunnelBuild.pairId) as SWBuildWireTunnel
			#pairId 失效（存档 id 重排/对方已被删）时按未配对处理，别把 null 塞进 wireGroup
			if pairTunnel:
				wireGroupBuilds.append({"build":pairTunnel,"dir":posmod(buildRef.rotation+3,4)})
			else:
				tunnelBuild.pairId = -1
		var wireNet:SWNet = SWNet.new()
		for wBuildItem:Dictionary in wireGroupBuilds:
			var wBuild = wBuildItem["build"]
			var dir = wBuildItem["dir"]
			wBuild.getCircuitCompoent().setNet(wireNet,dir)
			wireNet.wireGroup.addWireBuild(wBuild)
		wireNet.buildChunkIndex()
	pass
			
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(swBuildManager)
	
func resetPortState() -> void:
	super.resetPortState()
	setNet(null,0)

func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildRef.buildStateChanged(value)
	pass
