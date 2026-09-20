class_name SWBuildWireCross extends SWBuildWireCom

var v_net:SWNet = null
var h_net:SWNet = null
func rotOnce() -> void:
	pass
	
func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir) -> SWBuildItemDefine:
	var build = super.getDirBuild(swBuildManager,rot)
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
	
func setNet(srcNet:SWNet,dir:SWDefine.SW_Dir) -> void:
	#net = srcNet
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
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
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		if SWCommon.IsWireBuild(nextBuild):
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

func resetPortState(swBuildManager:SWBuildManager) -> void:
	super.resetPortState(swBuildManager)
	drawRect = buildDefine.atlasTextureOff.region
	v_net = null
	h_net = null
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	connectWireGroup(self,swBuildManager)

func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal:
	return SWDefine.CircuitSignal.NONE
	
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	buildStateChanged(value)
	pass
