class_name SWBuildWireCross extends SWBuildWireCom

var v_net:SWNet = null
var h_net:SWNet = null
func rotOnce() -> void:
	pass
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var build = super.getDirBuild(swBuildManager,rot)
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
	#net = srcNet
	var circuitCompoent := getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	if dir == 0 or dir == 2:
		v_net = srcNet
		circuitCompoent.pinNetMap[0] = v_net
		circuitCompoent.pinNetMap[2] = v_net
	elif dir == 1 or dir == 3:
		h_net = srcNet
		circuitCompoent.pinNetMap[1] = h_net
		circuitCompoent.pinNetMap[3] = h_net
	
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	loaders = []
	for driver:Dictionary in drivers:
		var dir = driver["pinDir"]
		if dir == 0 or dir == 2:
			v_net.setNet(drivers,loaders)
		if dir == 1 or dir == 3:
			h_net.setNet(drivers,loaders)
	
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
		var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		if SwCommon.IsWireBuild(nextBuild):
			continue
		if nextBuild.portIsInput(antiDir):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			if pinIndex == 0 or pinIndex == 2:
				v_net.addLoader({"build":nextBuild,"pinDir":antiDir})
			if pinIndex == 1 or pinIndex == 3:
				h_net.addLoader({"build":nextBuild,"pinDir":antiDir})
	return []

func reCalSignals() -> Array[SWBuildItemDefine]:
	return [self]

func resetPortState() -> void:
	super.resetPortState()
	drawRect = buildDefine.atlasTextureOff.region
	v_net = null
	h_net = null
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(self,swBuildManager)

func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal:
	return SwDefine.CircuitSignal.NONE
	
func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
