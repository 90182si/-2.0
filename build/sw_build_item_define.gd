#建筑物定义
@abstract
class_name SWBuildItemDefine extends RefCounted
var innerData:SWDefine.SWBuildInnerData = null
var id:int
var buildAxisPos:Vector2i
var buildDefine:SWBuildDefine


var compoent:Dictionary[SWDefine.BuildCompoentType,SWBuildCompoent] = {}
func getCompoent(compoentType:SWDefine.BuildCompoentType) -> SWBuildCompoent:
	return compoent.get_or_add(compoentType,SWCommon.CreateCompoent(compoentType))
	
var rotation:SWDefine.SW_Dir = 0:
	set(new_value):
		rotation = new_value
		rotation = posmod(rotation,4)

func rotOnce() -> void:
	rotation += 1
	pass
	
var signal_state:int = SWDefine.CircuitSignal.NONE
var circuit_on:bool = false
var tunnel_pair_id:int = -1
var tunnel_extra_data:int = 0
var comp_type:SWDefine.CircuitComponentType = SWDefine.CircuitComponentType.NONE
var in_loop:bool = false
var _buildingExpr:bool = false
var circuit:SWDefine.SWCircuitData = null
var drawRect:Rect2

func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
	innerData = SWDefine.SWBuildInnerData.new()
	buildAxisPos = axisPos
	buildDefine = buildDef
	setPortFlag()
	var rotCount:int = rot
	for i in range(rotCount):
		rotOnce()
	id = SWCommon.GenNextBuildId()
	if buildDef:
		comp_type = buildDef.circuit_component_type
	drawRect = buildDefine.atlasTextureOff.region

@abstract
func setPortFlag() -> void

func getDirBuild(swBuildManager:SWBuildManager,rot:SWDefine.SW_Dir) -> SWBuildItemDefine:
	var nextPos:Vector2i = buildAxisPos + 128*SWDefine.dir_to_vec(rot)
	var nextBuild:SWBuildItemDefine = swBuildManager.getBuild(nextPos)
	if nextBuild == null:
		return null
	if nextBuild.bIsToBeRemoved():
		return null
	var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(rot)
	var v:int = posmod(3-antiDir,4)
	if not nextBuild.isPort(antiDir):
		return null
	#if nextBuild.bLinkedPort(v):
		#return null
	if SWCommon.IsWireBuild(self) or SWCommon.IsWireBuild(nextBuild):
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
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		setLinkedPort(pinIndex)
		nextBuild.setLinkedPort(antiDir)
		nextBuild.setDriverOrLoader([{"build":self,"pinDir":pinIndex}],[{"build":nextBuild,"pinDir":antiDir}])
	return []

func onPressed(_pressed:bool) -> void:
	pass

func resetPortState(swBuildManager:SWBuildManager) -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.resetPortState()
	
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

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	signal_state = signalValue
	return
	
@abstract
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal

func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void:
	pass

func reCalSignals() -> Array[SWBuildItemDefine]:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	var v = getValue(SWDefine.SW_Dir.UP)
	if v > 0:
		buildStateChanged(SWDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SWDefine.CircuitSignal.LOW)
	return [self]

func isPort(value:int) -> bool:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.isPort(rotation,value)

func portIsOutput(value:int) -> bool:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.portIsOutput(rotation,value)
	
func portIsInput(value:int) -> bool:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.portIsInput(rotation,value)

func isLinkedPort(dir:SWDefine.SW_Dir) -> bool:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.isLinkedPort(rotation,dir)

func setLinkedPort(dir:SWDefine.SW_Dir) -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	return circuitCompoent.setLinkedPort(rotation,dir)

func bIsToBeRemoved() -> bool:
	return innerData.state == SWDefine.BuildState.TO_BE_REMOVED


func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct:
	return null

func getBuildExpr() -> void:
	pass
