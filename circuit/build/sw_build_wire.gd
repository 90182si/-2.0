class_name SWBuildWire extends SWBuildWireCom

var net:SWNet = null

func rotOnce() -> void:
	pass
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var build = super.getDirBuild(swBuildManager,rot)
	if build is SWBuildWire:
		var wireBuild = build as SWBuildWire
		if wireBuild.buildDefine.buildName != buildDefine.buildName:
			return null
	return build

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	super.buildStateChanged(signalValue)
	if signalValue == SwDefine.CircuitSignal.LOW:
		drawRect = buildDefine.atlasTextureOff.region
	elif signalValue == SwDefine.CircuitSignal.HIGH:
		drawRect = buildDefine.atlasTextureOn.region

func setPortFlag() -> void:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.UP,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.RIGHT,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.DOWN,SwDefine.CircuitPinType.WIRE)
	circuitCompoent.setPinDefine(SwDefine.SW_Dir.LEFT,SwDefine.CircuitPinType.WIRE)
	pass


	
func setNet(srcNet:SWNet,dir:SwDefine.SW_Dir) -> void:
	net = srcNet
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	for pinIndex in range(3,-1,-1):
		circuitCompoent.pinNetMap[pinIndex] = srcNet

			
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	net.setNet(drivers,loaders)
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
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
		var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		if SwCommon.IsWireBuild(nextBuild):
			continue
		if nextBuild.portIsInput(antiDir):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [self]

func resetPortState() -> void:
	super.resetPortState()
	drawRect = buildDefine.atlasTextureOff.region
	setNet(null,0)
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(self,swBuildManager)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
