class_name SWCommon extends Node

static var id = 0
static func GenNextBuildId() -> int:
	id += 1
	return id
	
static func GetAngleBySWDir(dir:SWDefine.SW_Dir) -> int:
	match dir:
		SWDefine.SW_Dir.UP:
			return 0
		SWDefine.SW_Dir.DOWN:
			return 180
		SWDefine.SW_Dir.RIGHT:
			return 270
		SWDefine.SW_Dir.LEFT:
			return 90
	return 0

static func GetGlobalPosByViewPos(viewPos: Vector2, viewport: Viewport) -> Vector2:
	var canvas_transform := viewport.get_canvas_transform()
	return canvas_transform.affine_inverse() * viewPos

#获取某个位置对应网格的起始坐标
static func GetGridPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/Vector2(SWDefine.GRID_SIZE)
	var pos = pos1.floor()
	var gridPos:Vector2i = Vector2i(pos)*SWDefine.GRID_SIZE
	return gridPos

static func GetChunkPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/(Vector2(SWDefine.GRID_SIZE)*SWDefine.CHUNK_SIZE)
	var pos = pos1.floor()
	var chunkPos:Vector2i = Vector2i(pos)*SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE
	return chunkPos

#以rotCenter为旋转中心，对srcPos旋转deg度
static func RotationPos(srcPos:Vector2,deg:float,rotCenter:Vector2) -> Vector2:
	if deg == 0.0:
		return srcPos
	return (srcPos - rotCenter).rotated(deg_to_rad(deg)) + rotCenter

static func IsWireBuild(build:SWBuildItemDefine) -> bool:
	if build.comp_type == SWDefine.CircuitComponentType.WIRE:
		return true
	return false
	
static func IsWireEndBuild(build:SWBuildItemDefine) -> bool:
	if build.comp_type == SWDefine.CircuitComponentType.LED:
		return true
	return false
	
static func CreateCompoent(compoentType:SWDefine.BuildCompoentType) -> SWBuildCompoent:
	match compoentType:
		SWDefine.BuildCompoentType.CIRCUIT:
			return SWBuildCompoentCircuit.new()
	return null

# 提取所有 [] 内文本，返回数组
static func get_all_text_in_brackets(input: String) -> Array[String]:
	var regex = RegEx.create_from_string(r"\[(.*?)\:")
	var matches: Array[RegExMatch] = regex.search_all(input)
	var res: Array[String] = []
	for m in matches:
		res.append(m.get_string(1))
	return res

static func AndValues(args: Array) -> int:
	var v:int = 0
	var b:bool = false
	for arg in args:
		if b == false:
			b = true
			v = arg.optFunc.call(arg.args)
			continue
		v &= arg.optFunc.call(arg.args)
	return v

static func NotValues(args: Array) -> int:
	var arg = null
	if args.size() > 0:
		arg = args[0]
	if arg is SWDefine.SWBuildPinStruct:
		if arg.build.getValue(null,arg.dir) == SWDefine.CircuitSignal.HIGH:
			return 0
		return 1
	elif arg is SWDefine.SWCircuitStruct:
		return 1-arg.optFunc.call(arg.args)
	return 0

static func EqualValues(args: Array) -> int:
	var arg = null
	if args.size() > 0:
		arg = args[0]
	if arg is SWDefine.SWBuildPinStruct:
		if arg.build.getValue(null,arg.dir) == SWDefine.CircuitSignal.HIGH:
			return 1
		return 0
	elif arg is SWDefine.SWCircuitStruct:
		return arg.optFunc.call(arg.args)
	return 0
