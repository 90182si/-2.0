extends Node

static var id = 0
static func GenNextBuildId() -> int:
	id += 1
	return id
	
static func GetAngleBySWDir(dir:SwDefine.SW_Dir) -> int:
	match dir:
		SwDefine.SW_Dir.UP:
			return 0
		SwDefine.SW_Dir.DOWN:
			return 180
		SwDefine.SW_Dir.RIGHT:
			return 270
		SwDefine.SW_Dir.LEFT:
			return 90
	return 0

static func GetGlobalPosByViewPos(viewPos: Vector2, viewport: Viewport) -> Vector2:
	var canvas_transform := viewport.get_canvas_transform()
	return canvas_transform.affine_inverse() * viewPos

#获取某个位置对应网格的起始坐标
static func GetGridPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/Vector2(SwDefine.GRID_SIZE)
	var pos = pos1.floor()
	var gridPos:Vector2i = Vector2i(pos)*SwDefine.GRID_SIZE
	return gridPos

static func GetChunkPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/(Vector2(SwDefine.GRID_SIZE)*SwDefine.CHUNK_SIZE)
	var pos = pos1.floor()
	var chunkPos:Vector2i = Vector2i(pos)*SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE
	return chunkPos

#以rotCenter为旋转中心，对srcPos旋转deg度
static func RotationPos(srcPos:Vector2,deg:float,rotCenter:Vector2) -> Vector2:
	if deg == 0.0:
		return srcPos
	return (srcPos - rotCenter).rotated(deg_to_rad(deg)) + rotCenter

static func IsWireBuild(build:SWBuildItemDefine) -> bool:
	if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE \
		or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE_BRIDGE \
		or build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE_TUNNEL:
		return true
	return false
	
static func IsWireEndBuild(build:SWBuildItemDefine) -> bool:
	if build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.LED:
		return true
	return false
	
static func CreateCompoent(compoentType:SwDefine.BuildCompoentType) -> SWBuildCompoent:
	match compoentType:
		SwDefine.BuildCompoentType.CIRCUIT:
			return SWBuildCompoentCircuit.new()
		SwDefine.BuildCompoentType.CIRCUIT_WIRE:
			return SWBuildCompoentCircuitWire.new()
		SwDefine.BuildCompoentType.CIRCUIT_WIRE_CROSS:
			return SWBuildCompoentCircuitWireCross.new()
		SwDefine.BuildCompoentType.CIRCUIT_SOURCE:
			return SWBuildCompoentCircuitSource.new()
		SwDefine.BuildCompoentType.CIRCUIT_LED:
			return SWBuildCompoentCircuitLed.new()
		SwDefine.BuildCompoentType.CIRCUIT_NOT:
			return SWBuildCompoentCircuitNot.new()
		SwDefine.BuildCompoentType.RENDER_ABLE:
			return SWBuildCompoentRenderable.new()
		SwDefine.BuildCompoentType.CIRCUIT_WIRE_TUNNEL:
			return SWBuildCompoentCircuitTunnel.new()
		SwDefine.BuildCompoentType.CIRCUIT_CLOCK_SIGGEN:
			return SWBuildCompoentCircuitClockSiggen.new()
		SwDefine.BuildCompoentType.CIRCUIT_REGISTER:
			return SWBuildCompoentCircuitRegister.new()
	return null

# 提取所有 [] 内文本，返回数组
static func get_all_text_in_brackets(input: String) -> Array[String]:
	var regex = RegEx.create_from_string(r"\[(.*?)\:")
	var matches: Array[RegExMatch] = regex.search_all(input)
	var res: Array[String] = []
	for m in matches:
		res.append(m.get_string(1))
	return res

#求值轮次：每次电路重建或信号变化时自增，表达式节点缓存按轮次失效
static var evalEpoch:int = 0
#连线翻转变更戳：任一 net 电平变化时自增并写进该 net.patchStamp，
#区块补丁按它判断「本区块自上次补丁后有哪些连线变了颜色」
static var netPatchStamp:int = 0
static var dbgEvaluated:int = 0
static var dbgQueue:int = 0
static func NextEvalEpoch() -> int:
	evalEpoch += 1
	return evalEpoch

#求值一个表达式节点；同一轮次内共享子树只计算一次，避免重复递归导致的指数级耗时
static func EvalStruct(cirStruct:SwDefine.SWCircuitStruct) -> int:
	if cirStruct == null:
		return 0
	if cirStruct.cachedEpoch == evalEpoch:
		return cirStruct.cachedValue
	var v:int = cirStruct.optFunc.call(cirStruct.args)
	cirStruct.cachedEpoch = evalEpoch
	cirStruct.cachedValue = v
	return v
	
static func AndValues(args: Array) -> int:
	var v:int = 0
	var b:bool = false
	for arg in args:
		if b == false:
			b = true
			v = EvalStruct(arg)
			continue
		v &= EvalStruct(arg)
	return v
	
static func NotAndValues(args: Array) -> int:
	var v:int = 0
	var b:bool = false
	for arg in args:
		if b == false:
			b = true
			v = EvalStruct(arg)
			continue
		v &= EvalStruct(arg)
	return 1-v
	
static func NotValues(args: Array) -> int:
	var arg = null
	if args.size() > 0:
		arg = args[0]
	if arg is SwDefine.SWBuildPinStruct:
		if arg.build.getCircuitCompoent().getValue(arg.dir) == SwDefine.CircuitSignal.HIGH:
			return 0
		return 1
	elif arg is SwDefine.SWCircuitStruct:
		return 1-EvalStruct(arg)
	return 0

static func EqualValues(args: Array) -> int:
	var arg = null
	if args.size() > 0:
		arg = args[0]
	if arg is SwDefine.SWBuildPinStruct:
		if arg.build.getCircuitCompoent().getValue(arg.dir) == SwDefine.CircuitSignal.HIGH:
			return 1
		return 0
	elif arg is SwDefine.SWCircuitStruct:
		return EvalStruct(arg)
	return 0

static func GetWireColor(wireName:String) -> Array[Color]:
	var retArr:Array[Color] = []
	match wireName:
		"电线A":
			retArr = [Color(0.29, 0.036, 0.07, 1.0),Color(0.726, 0.165, 0.235, 1.0)]
		"电线B":
			retArr = [Color(0.032, 0.253, 0.137, 1.0),Color(0.134, 0.683, 0.405, 1.0)]
		_:
			retArr = [Color(0.032, 0.253, 0.137, 1.0),Color(0.134, 0.683, 0.405, 1.0)]
	return retArr

# 循环依赖（反馈环）元件与电线的警示色
static func GetLoopColor() -> Color:
	return Color(0.293, 0.001, 0.511, 1.0)
