#建筑物定义
@abstract
class_name SWBuildItemDefine extends RefCounted
var innerData:SwDefine.SWBuildInnerData = null
var id:int
var buildAxisPos:Vector2i
var buildDefine:SWBuildDefine


var compoent:Dictionary[SwDefine.BuildCompoentType,SWBuildCompoent] = {}
func getCompoent(compoentType:SwDefine.BuildCompoentType) -> SWBuildCompoent:
	return compoent.get_or_add(compoentType,SwCommon.CreateCompoent(compoentType))
	
var rotation:SwDefine.SW_Dir = 0:
	set(new_value):
		rotation = new_value
		rotation = posmod(rotation,4)

func rotOnce() -> void:
	rotation += 1
	pass
	
var signal_state:int = SwDefine.CircuitSignal.NONE
var circuit_on:bool = false
var tunnel_pair_id:int = -1
var tunnel_extra_data:int = 0
var comp_type:SwDefine.CircuitComponentType = SwDefine.CircuitComponentType.NONE
var in_loop:bool = false
var _buildingExpr:bool = false
var circuit:SwDefine.SWCircuitData = null
var drawRect:Rect2
#性能优化：缓存 CIRCUIT 组件引用，避免热点端口判断反复走 getCompoent 字典查找
var _circuitCompoent:SWBuildCompoentCircuit = null

func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
	innerData = SwDefine.SWBuildInnerData.new()
	buildAxisPos = axisPos
	buildDefine = buildDef
	setPortFlag()
	var rotCount:int = rot
	for i in range(rotCount):
		rotOnce()
	id = SwCommon.GenNextBuildId()
	if buildDef:
		comp_type = buildDef.circuit_component_type
	drawRect = buildDefine.atlasTextureOff.region

@abstract
func setPortFlag() -> void

func getDirBuild(swBuildManager:SWBuildManager,rot:SwDefine.SW_Dir) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + 128*SwDefine.dir_to_vec(rot)
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	if nextBuild.bIsToBeRemoved():
		return null
	var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(rot)
	if not nextBuild.isPort(antiDir):
		return null
	if SwCommon.IsWireBuild(self) or SwCommon.IsWireBuild(nextBuild):
		return nextBuild
	if portIsOutput(rot) and nextBuild.portIsInput(antiDir):
		return nextBuild
	if portIsInput(rot) and nextBuild.portIsOutput(antiDir):
		return nextBuild
	return null
	
func setDriverOrLoader(drivers:Array,loaders:Array) -> void:
	var net:SWNet = SWNet.new()
	net.setNet(drivers,loaders)
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#这里的portIsInput(pinIndex)会导致wire所有端口跳过，wire连接的下一个输入口没法被获取到
		if bIsToBeRemoved() or portIsInput(pinIndex):
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild == null:
			continue
		var antiDir:SwDefine.SW_Dir = SwDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		setLinkedPort(pinIndex)
		nextBuild.setLinkedPort(antiDir)
		nextBuild.setDriverOrLoader([{"build":self,"pinDir":pinIndex}],[{"build":nextBuild,"pinDir":antiDir}])
	return []

func onPressed(_pressed:bool) -> void:
	pass

func getCircuitCompoent() -> SWBuildCompoentCircuit:
	if _circuitCompoent == null:
		_circuitCompoent = getCompoent(SwDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return _circuitCompoent
	
func resetPortState() -> void:
	in_loop = false
	getCircuitCompoent().resetPortState()
	
func initPortState(swBuildManager:SWBuildManager) -> void:
	pass
	
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array:
	var linkedBuilds:Array = []
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild:
			linkedBuilds.append({"build":nextBuild,"dir":pinIndex})
	return linkedBuilds

func buildStateChanged(signalValue:SwDefine.CircuitSignal) -> void:
	signal_state = signalValue
	return
	
@abstract
func getValue(dir:SwDefine.SW_Dir) -> SwDefine.CircuitSignal

func setValue(dir:SwDefine.SW_Dir,value:SwDefine.CircuitSignal) -> void:
	pass

func reCalSignals() -> Array[SWBuildItemDefine]:
	var v = getValue(SwDefine.SW_Dir.UP) == SwDefine.CircuitSignal.HIGH
	if v:
		buildStateChanged(SwDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SwDefine.CircuitSignal.LOW)
	return [self]

func isPort(value:int) -> bool:
	return getCircuitCompoent().isPort(rotation,value)

func portIsOutput(value:int) -> bool:
	return getCircuitCompoent().portIsOutput(rotation,value)
	
func portIsInput(value:int) -> bool:
	return getCircuitCompoent().portIsInput(rotation,value)

func isLinkedPort(dir:SwDefine.SW_Dir) -> bool:
	return getCircuitCompoent().isLinkedPort(rotation,dir)

func setLinkedPort(dir:SwDefine.SW_Dir) -> void:
	return getCircuitCompoent().setLinkedPort(rotation,dir)

func bIsToBeRemoved() -> bool:
	return innerData.state == SwDefine.BuildState.TO_BE_REMOVED


func getExpr(pinDir:SwDefine.SW_Dir) -> SwDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
