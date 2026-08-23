class_name SWDefine extends Node

const CHUNK_SIZE = 16
const VIEW_MAX_LEVEL = 4
const VIEW_MIN_LEVEL = -30-15
const VIEW_NEXT_LEVEL = -14
const GRID_SIZE = Vector2i(128,128)

enum GridDrawMode {
	Tiling,   #平铺显示
	ByContent, #根据数据内容显示
	ByHold,   #显示手持
	HoldShadow#手持阴影
}

enum SW_Dir {
	UP,
	RIGHT,
	DOWN,
	LEFT
}

enum BuildOpr{
	Place,
	Erase,
	BeginSelect,
	EndSelect,
	Selecting,
	Rotate
}

# 加载层级优先级
enum ChunkPriority {
	HIGH = 0,  # 即时层（0-2）
	MEDIUM = 1,  # 缓冲层（3-5）
	LOW = 2     # 边缘层（6-10）
}

# 区块状态枚举
enum ChunkStatus {
	EMPTY,
	TERRAIN_GENERATED,
	FULLY_LOADED,#可见
	UNVISIBLE,#不可见
	UNLOADING,
	UNLOADED
}

enum CircuitPinType{
	NONE,
	INPUT,
	OUTPUT
}
#电路信号枚举
enum CircuitSignal{
	NONE,
	LOW,
	HIGH
}

#电路元件类型枚举
enum CircuitComponentType{
	NONE,
	BUTTON,       #按钮：按下时输出HIGH
	SWITCH,       #开关：切换状态
	LED,          #灯泡：接收信号发光
	WIRE_STRAIGHT,#直线电线
	WIRE_BENT,    #弯头电线
	WIRE_BRIDGE,  #十字不相交电线
	NOT_GATE,     #非门
	WIRE_TUNNEL   #地下隧道传送信号
}

#建筑物状态
enum BuildState{
	IDLE,
	SELECTED
}

#视口偏移与缩放
class SWTransformData extends RefCounted:
	var offset:Vector2 = Vector2(0,0)
	var scale:Vector2 = Vector2(1.0,1.0)
	
#地图网格图集定义
#class SWDrawGridDefine extends RefCounted:
	#var gridPos:Vector2i = Vector2i(0,0)#需要绘制在网格的哪个位置
	#var atlasRegion:Vector4i = Vector4i(0,0,0,0)#图集位置
	#var angle:SW_Dir = SW_Dir.UP#方向

#电路元件方向映射辅助
static func get_circuit_dir(rot:int) -> int:
	var r = ((rot % 360) + 360) % 360
	var step = r / 90
	return (4 - step) % 4

static func get_output_dir(compType:int, rot:int) -> int:
	match compType:
		CircuitComponentType.BUTTON, CircuitComponentType.SWITCH:
			return get_circuit_dir(rot)
		CircuitComponentType.NOT_GATE:
			return get_circuit_dir(rot)
		_:
			return -1

static func get_input_dirs(compType:int, rot:int) -> Array[int]:
	var dirs:Array[int] = []
	var d = get_circuit_dir(rot)
	match compType:
		CircuitComponentType.BUTTON, CircuitComponentType.SWITCH:
			pass
		CircuitComponentType.LED:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.WIRE_STRAIGHT:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.WIRE_BENT:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.WIRE_BRIDGE:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.NOT_GATE:
			dirs = [(d + 2) % 4]
		CircuitComponentType.WIRE_TUNNEL:
			dirs = [0, 1, 2, 3]
		_:
			pass
	return dirs

static func get_output_dirs(compType:int, rot:int) -> Array[int]:
	var dirs:Array[int] = []
	var d = get_circuit_dir(rot)
	match compType:
		CircuitComponentType.BUTTON, CircuitComponentType.SWITCH:
			dirs = [d]
		CircuitComponentType.WIRE_STRAIGHT:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.WIRE_BENT:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.WIRE_BRIDGE:
			dirs = [0, 1, 2, 3]
		CircuitComponentType.NOT_GATE:
			dirs = [d]
		CircuitComponentType.WIRE_TUNNEL:
			dirs = [0, 1, 2, 3]
		_:
			pass
	return dirs

static func opposite_dir(dir:int) -> int:
	return (dir + 2) % 4
	
static func get_wire_dir_except(dir:int) -> Array[int]:
	var dirs:Array[int] = [0,1,2,3]
	match dir:
		0:dirs.erase(2)
		1:dirs.erase(3)
		2:dirs.erase(0)
		3:dirs.erase(1)
	return dirs

static func dir_to_vec(dir:int) -> Vector2i:
	match dir:
		0: return Vector2i(0, -1)
		1: return Vector2i(1, 0)
		2: return Vector2i(0, 1)
		3: return Vector2i(-1, 0)
		_: return Vector2i.ZERO

static func getAntiDir(dir:SW_Dir) -> SW_Dir:
	match dir:
		SW_Dir.UP: return SW_Dir.DOWN
		SW_Dir.DOWN: return SW_Dir.UP
		SW_Dir.RIGHT: return SW_Dir.LEFT
		SW_Dir.LEFT: return SW_Dir.RIGHT
	return SW_Dir.UP
	
static func getDirValue(dir:SW_Dir) -> int:
	match dir:
		SW_Dir.UP: return 0
		SW_Dir.DOWN: return 1
		SW_Dir.RIGHT: return 2
		SW_Dir.LEFT: return 3
	return 0

static func SWBuildCreator(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> SWBuildItemDefine:
	match buildDef.buildName:
		"按钮":return SWBuildButton.new(axisPos,buildDef,rot)
		"灯泡":return SWBuildLed.new(axisPos,buildDef,rot)
		"非门":return SWBuildNot.new(axisPos,buildDef,rot)
		"电线A":return SWBuildWire.new(axisPos,buildDef,rot)
		"电线B":return SWBuildWire.new(axisPos,buildDef,rot)
		"开关":return SWBuildButton.new(axisPos,buildDef,rot)
		_:return SWBuildNone.new(axisPos,buildDef,rot)
	return null

## 卡诺图数据 - 存储输入到输出的映射关系
class SWKarnaughMap extends RefCounted:
	var input_ids: Array[int] = []
	var output_ids: Array[int] = []
	## 真值表: 输入位掩码(int) -> 输出位掩码(int)
	var truth_table: Dictionary = {}

	func to_dict() -> Dictionary:
		var d := {}
		d["inputs"] = input_ids.duplicate()
		d["outputs"] = output_ids.duplicate()
		var tt := {}
		for k in truth_table.keys():
			tt[str(k)] = truth_table[k]
		d["truth_table"] = tt
		return d

	static func from_dict(d: Dictionary) -> SWKarnaughMap:
		var km := SWKarnaughMap.new()
		km.input_ids = d.get("inputs", [])
		km.output_ids = d.get("outputs", [])
		var tt = d.get("truth_table", {})
		if tt is Dictionary:
			for k in tt.keys():
				km.truth_table[int(k)] = int(tt[k])
		return km

	## 根据输入状态查询输出状态
	## inputs: {元件id: bool(true=HIGH)} -> {元件id: bool}
	func evaluate(inputs: Dictionary) -> Dictionary:
		var idx := 0
		for i in range(input_ids.size()):
			if inputs.get(input_ids[i], false):
				idx |= (1 << i)
		var output_mask: int = truth_table.get(idx, 0)
		var result := {}
		for i in range(output_ids.size()):
			result[output_ids[i]] = bool(output_mask & (1 << i))
		return result

	func get_input_count() -> int:
		return input_ids.size()

	func get_output_count() -> int:
		return output_ids.size()

## 可独立运行的电路单元（用于后续从存档加载独立运行）
class SWCircuitUnitData extends RefCounted:
	var karnaugh_map: SWKarnaughMap = null
	var component_data: Array[Dictionary] = []

	func evaluate(inputs: Dictionary) -> Dictionary:
		if karnaugh_map:
			return karnaugh_map.evaluate(inputs)
		return {}

	func to_dict() -> Dictionary:
		var d := {}
		d["karnaugh_map"] = karnaugh_map.to_dict() if karnaugh_map else {}
		d["components"] = component_data.duplicate(true)
		return d

	static func from_dict(d: Dictionary) -> SWCircuitUnitData:
		var unit := SWCircuitUnitData.new()
		var km_data = d.get("karnaugh_map", {})
		if km_data is Dictionary and not km_data.is_empty():
			unit.karnaugh_map = SWKarnaughMap.from_dict(km_data)
		unit.component_data = d.get("components", [])
		return unit

class SWCircuitData extends RefCounted:
	var circuitID:int
	var buildIdArr:Array[int] = []
	var signalMaps = {}
	var signalAntiMaps = {}
	var signalValues = {}
	func _init() -> void:
		circuitID = SWCommon.GenNextBuildId()



# 区块数据结构（存储核心信息，不直接存储渲染节点）
class SWDrawChunkData extends RefCounted:
	var chunk_pos: Vector2  # 区块坐标（cx, cz）
	var world_pos: Vector2  # 世界坐标（x, y）
	var status: ChunkStatus = ChunkStatus.EMPTY
	var priority: ChunkPriority = ChunkPriority.LOW
	var mesh_instance: SWMultiMeshInstance2D = null  # 批量渲染节点
	#var multi_mesh: MultiMesh = null  # 批量网格数据
	func init() -> void:
		chunk_pos = Vector2.ZERO
		world_pos = Vector2.ZERO
		status = ChunkStatus.EMPTY
		priority = ChunkPriority.LOW
		if not mesh_instance:
			mesh_instance = preload("res://sw_multi_mesh_instance_2d.tscn").instantiate() 
			mesh_instance.chunkPtr = self
			mesh_instance._hadDraw = false
		mesh_instance.reUse()
			#multi_mesh = mesh_instance.multimesh

class SWBuildStateStrategy extends RefCounted:
	var innerData:SWBuildInnerData = null
	func _init() -> void:
		pass
	func stateChanged(innerData:SWBuildInnerData,state:BuildState) -> void:
		innerData.mask_color = Color(1,1,1,1)
		
class SWBuildStateSelected extends SWBuildStateStrategy:
	func stateChanged(innerData:SWBuildInnerData,state:BuildState) -> void:
		if state == BuildState.IDLE:
			innerData.mask_color = Color(1,1,1,1)
		elif state == BuildState.SELECTED:
			innerData.mask_color = Color(0.157, 0.557, 0.906, 0.788)

#建筑物内部数据
class SWBuildInnerData extends Resource:
	var mask_color:Color = Color(1.0, 1.0, 1.0, 1.0)
	var buildStateStrategy:SWBuildStateStrategy = null
	var state:BuildState = BuildState.IDLE:
		set(s):
			state = s
			if buildStateStrategy:
				buildStateStrategy.stateChanged(self,s)
	
	func _init() -> void:
		buildStateStrategy = SWBuildStateSelected.new()
	pass
