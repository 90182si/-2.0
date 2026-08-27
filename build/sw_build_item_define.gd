#建筑物定义
@abstract
class_name SWBuildItemDefine extends RefCounted
var innerData:SWDefine.SWBuildInnerData = null
var id:int
var buildAxisPos:Vector2i
var buildDefine:SWBuildDefine
#0b1111代表四边都有端口
var canConBit:int = 0
#0b1111代表四边都是输出口
var portDefine:int = 0
#0b1111代表四边都输出高电平
var portValue:int = 0

var rotation:SWDefine.SW_Dir = 0:
	set(new_value):
		rotation = new_value
		rotation %= 4

func rotOnce() -> void:
	canConBit = (canConBit >> 1)+((canConBit&1)<<3)
	portDefine = (portDefine >> 1)+((portDefine&1)<<3)
	
var signal_state:int = SWDefine.CircuitSignal.NONE
var circuit_on:bool = false
var tunnel_pair_id:int = -1
var tunnel_extra_data:int = 0
var comp_type:int = SWDefine.CircuitComponentType.NONE
var in_loop:bool = false
var circuit:SWDefine.SWCircuitData = null
var drawRect:Rect2

var linkedPort:int = 0
#端口连接的id
#var linkedID:Dictionary[SWDefine.SW_Dir,int] = {}

func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
	innerData = SWDefine.SWBuildInnerData.new()
	buildAxisPos = axisPos
	buildDefine = buildDef
	rotation = rot
	id = SWCommon.GenNextBuildId()
	if buildDef:
		comp_type = buildDef.circuit_component_type
	drawRect = buildDefine.atlasTextureOff.region
	setPortFlag()

#@abstract
func setPortFlag() -> void:
	canConBit = 0b0000
	portDefine = 0b0000

@abstract
func getLinkedBuilds(swBuildManager:SWBuildManager) -> Array

func onPressed(_pressed:bool) -> void:
	pass

func bLinkedPort(dir:SWDefine.SW_Dir) -> bool:
	return (linkedPort&(1<<dir)) > 0

func setLinkedPort(dir:SWDefine.SW_Dir) -> void:
	linkedPort|=(1<<dir)

func resetPortCon() -> void:
	linkedPort = 0

#@abstract
func getBuildIOConnectBuildArr(swBuildManager:SWBuildManager) -> Array[SWBuildItemDefine]:
	return []

func buildStateChanged(signalValue:SWDefine.CircuitSignal) -> void:
	return

func reCalSignals(swBuildManager:SWBuildManager) -> void:
	var v = 0
	var f = 1
	var depends = circuit.sourceSignalMap[id]
	for dependItem in depends:
		var vs = dependItem["signal"]
		var k = circuit.inputValues[dependItem["from"]] > 0
		if vs == '!':
			k = 1 - k
		if f:
			f=0
			v = k
		else:
			v &= k
	if v > 0:
		buildStateChanged(SWDefine.CircuitSignal.HIGH)
	else:
		buildStateChanged(SWDefine.CircuitSignal.LOW)
	pass

func isPort(value:int) -> bool:
	return canConBit&value > 0

func portIsOutput(value:int) -> bool:
	return portDefine&value > 0
	
func portIsInput(value:int) -> bool:
	return portDefine&value == 0

func isWireBuild() -> bool:
	return portDefine&0b10000 > 0
