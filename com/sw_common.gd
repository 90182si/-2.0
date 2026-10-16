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
static func NextEvalEpoch() -> int:
	evalEpoch += 1
	return evalEpoch

#求值一个表达式节点；同一轮次内共享子树只计算一次，避免重复递归导致的指数级耗时
static func EvalStruct(cirStruct:SwDefine.SWCircuitStruct) -> int:
	if cirStruct == null:
		return 0
	if cirStruct.cachedEpoch == evalEpoch:
		return cirStruct.cachedValue
	# 新增: op 单态分派（op == -1 时走旧路径兜底）
	if cirStruct.op != -1:
		match cirStruct.op:
			SwDefine.CircuitOp.OP_LEAF:
				cirStruct.cachedValue = EvalLeaf(cirStruct.args[0])
			SwDefine.CircuitOp.OP_PASS:
				cirStruct.cachedValue = EvalArg(cirStruct, 0)
			SwDefine.CircuitOp.OP_NOT:
				cirStruct.cachedValue = 1 - EvalArg(cirStruct, 0)
			SwDefine.CircuitOp.OP_AND:
				cirStruct.cachedValue = EvalArgsAnd(cirStruct)
			SwDefine.CircuitOp.OP_NAND:
				cirStruct.cachedValue = 1 - EvalArgsAnd(cirStruct)
		cirStruct.cachedEpoch = evalEpoch
		return cirStruct.cachedValue
	# 旧路径兜底（op == -1）
	var v:int = cirStruct.optFunc.call(cirStruct.args)
	cirStruct.cachedEpoch = evalEpoch
	cirStruct.cachedValue = v
	return v

static func EvalArg(parent:SwDefine.SWCircuitStruct, i:int) -> int:
	if i >= parent.args.size():
		return 0
	var arg = parent.args[i]
	if arg is SwDefine.SWCircuitStruct:
		return EvalStruct(arg)
	elif arg is SwDefine.SWBuildPinStruct:
		return EvalLeaf(arg)
	return 0

static func EvalLeaf(pinStruct) -> int:
	var val = pinStruct.build.getCircuitCompoent().getValue(pinStruct.dir)
	return 1 if val == SwDefine.CircuitSignal.HIGH else 0

static func EvalArgsAnd(parent:SwDefine.SWCircuitStruct) -> int:
	if parent.args.size() == 0:
		return 0
	var v := EvalArg(parent, 0)
	for i in range(1, parent.args.size()):
		v &= EvalArg(parent, i)
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
			retArr = [Color(0.122, 0.395, 0.524, 1.0),Color(0.603, 0.84, 0.968, 1.0)]
		"电线B":
			retArr = [Color(0.335, 0.231, 0.737, 1.0),Color(0.721, 0.713, 0.977, 1.0)]
		_:
			retArr = [Color(0.122, 0.395, 0.524, 1.0),Color(0.603, 0.84, 0.968, 1.0)]
	return retArr

# 根据 net 的当前信号和电线名称，返回显示颜色
static func get_net_display_color(net: SWNet) -> Color:
	if net == null:
		return Color.TRANSPARENT
	var wire_name: String = net.wireGroup.wireName if net.wireGroup else ""
	var color_arr: Array[Color] = GetWireColor(wire_name)
	if net.curSignal == SwDefine.CircuitSignal.HIGH:
		return color_arr[1] if color_arr.size() > 1 else color_arr[0]
	return color_arr[0] if color_arr.size() > 0 else Color.TRANSPARENT

# 循环依赖（反馈环）元件与电线的警示色
static func GetLoopColor() -> Color:
	return Color(1.0, 0.0, 0.0, 1.0)
