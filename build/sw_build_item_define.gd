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
		rotation %= 4

func rotOnce() -> void:
	rotation += 1
	#canConBit = (canConBit >> 1)+((canConBit&1)<<3)
	#portDefine = (portDefine >> 1)+((portDefine&1)<<3)
	pass
	
var signal_state:int = SWDefine.CircuitSignal.NONE
var circuit_on:bool = false
var tunnel_pair_id:int = -1
var tunnel_extra_data:int = 0
var comp_type:int = SWDefine.CircuitComponentType.NONE
var in_loop:bool = false
var circuit:SWDefine.SWCircuitData = null
var drawRect:Rect2


#端口连接的id
#var linkedID:Dictionary[SWDefine.SW_Dir,int] = {}

func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
	innerData = SWDefine.SWBuildInnerData.new()
	buildAxisPos = axisPos
	buildDefine = buildDef
	#rotation = rot
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
	var v:int = (3-antiDir)%4
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
	
func getNet(swBuildManager:SWBuildManager) -> Array:
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		#如果这个方向的端口不可用 或者 是这个建筑物即将被删除 或者 这个端口是输入口
		if isLinkedPort(pinIndex):
			continue
		#这里的portIsInput(pinIndex)会导致wire所有端口跳过，wire连接的下一个输入口没法被获取到
		if bIsToBeRemoved() or (not SWCommon.IsWireBuild(self) and portIsInput(pinIndex)):
			continue
		#获取开关\按钮方向的建筑物
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild == null:
			continue
		var antiDir:SWDefine.SW_Dir = SWDefine.getAntiDir(pinIndex)
		#标记两个建筑物相应端口占用
		
		if not SWCommon.IsWireBuild(self) and SWCommon.IsWireBuild(nextBuild):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			var wireBuild := nextBuild as SWBuildWire
			wireBuild.net.addDriver({"build":self,"pinDir":pinIndex})
			#wireBuild.wireGroup.net.addLoader({"build":wireBuild,"pinDir":antiDir})
		elif SWCommon.IsWireBuild(self) and not SWCommon.IsWireBuild(nextBuild) and nextBuild.portIsInput(antiDir):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			var wireBuild := self as SWBuildWire
			wireBuild.net.addLoader({"build":nextBuild,"pinDir":antiDir})
			#wireBuild.wireGroup.net.addLoader({"build":self,"pinDir":antiDir})
		elif not SWCommon.IsWireBuild(self) and not SWCommon.IsWireBuild(nextBuild):
			setLinkedPort(pinIndex)
			nextBuild.setLinkedPort(antiDir)
			var net:SWNet = SWNet.new()
			net.setNet([{"build":self,"pinDir":pinIndex}],[{"build":nextBuild,"pinDir":antiDir}])
	return []

func onPressed(_pressed:bool) -> void:
	pass



func resetPortState() -> void:
	var circuitCompoent := getCompoent(SWDefine.BuildCompoentType.CIRCUIT) as SWBuildCompoentCircuit
	circuitCompoent.resetPortState()
	
	
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	var linkedBuilds:Array[SWBuildItemDefine] = []
	for pinIndex:int in range(3,-1,-1):
		if not isPort(pinIndex):
			continue
		var nextBuild:SWBuildItemDefine = getDirBuild(swBuildManager,pinIndex)
		if nextBuild:
			linkedBuilds.append(nextBuild)
	return linkedBuilds

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	signal_state = signalValue
	return

func calDepends(depends:Array) -> int:
	var v:int = 0
	var f = 1
	for dependItem in depends:
		var vs = dependItem["signal"]
		var k:int = 1 if circuit.inputValues[dependItem["from"]] > 0 else 0
		if vs == '!':
			k = 1 - k
		if f:
			f=0
			v = k
		else:
			v &= k
	return v
	
@abstract
func getValue(dir:SWDefine.SW_Dir) -> SWDefine.CircuitSignal

@abstract
func setValue(dir:SWDefine.SW_Dir,value:SWDefine.CircuitSignal) -> void

func reCalSignals(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
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


@abstract
func getExpr(pinDir:SWDefine.SW_Dir) -> SWDefine.SWCircuitStruct

@abstract
func getBuildExpr() -> void
