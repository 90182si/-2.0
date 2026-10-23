class_name SWBuildCompoentRenderable extends SWBuildCompoent
	
var buildRef:SWBuildItemDefine = null
var buildHasBase:bool = false
var buildHasAtlas:bool = false
var buildAtlasRotable:bool = true
var drawRect:Rect2

# ========== 渲染部件缓存 ==========
# 区块重绘时块内所有建筑都会调用 getRenderParts()，但绝大多数建筑本次并未变化。
# 用脏标记缓存部件列表，只有当该建筑的渲染状态（信号/旋转/环路/连接等）变化时才重建。
var _renderPartsCache: Array = []
var _renderPartsDirty: bool = true

# ========== 实例数据块缓存 ==========
# 每个部件的 16 个 float 已按 MultiMesh buffer 布局烘培好（含世界坐标、颜色、图集 rect），
# 区块绘制时对整个建筑只需 append_array 一次（一次 C++ memcpy）。
# 上万建筑时这是主要开销：逐实例逐字段的脚本赋值会放大成数百万次数组写入。
# [0]=x.x [1]=y.x [2]=0 [3]=x位移 [4]=x.y [5]=y.y [6]=0 [7]=y位移 [8..11]=颜色 [12..15]=图集rect
const INSTANCE_STRIDE: int = 16
var _instanceBlock: PackedFloat32Array = PackedFloat32Array()
var _blockValid: bool = false
# 烘培时的输入参数，任一变化都需要重新烘培
var _blockBaseX: float = 0.0
var _blockBaseY: float = 0.0
var _blockGridX: float = 0.0
var _blockGridY: float = 0.0
var _blockColor: Color = Color(0.0, 0.0, 0.0, 0.0)

func markRenderPartsDirty() -> void:
	_renderPartsDirty = true
	_blockValid = false

func getRenderParts() -> Array:
	if not _renderPartsDirty:
		return _renderPartsCache
	_renderPartsCache = _buildRenderParts()
	_renderPartsDirty = false
	_blockValid = false
	return _renderPartsCache

# 获取整块实例数据：世界坐标/颜色/图集均已烘培，参数未变时零计算直接复用
func getInstanceBlock(baseX: float, baseY: float, gridX: float, gridY: float, color: Color) -> PackedFloat32Array:
	if _blockValid and _blockBaseX == baseX and _blockBaseY == baseY \
			and _blockGridX == gridX and _blockGridY == gridY and _blockColor == color:
		return _instanceBlock
	_bakeInstanceBlock(baseX, baseY, gridX, gridY, color)
	return _instanceBlock

# 部件数量（不需要构建数据块）
func getRenderPartCount() -> int:
	return getRenderParts().size()

# 将部件列表烘培成可被 MultiMesh buffer 直接追加的扁平数组
func _bakeInstanceBlock(baseX: float, baseY: float, gridX: float, gridY: float, color: Color) -> void:
	var parts: Array = getRenderParts()
	var count: int = parts.size()
	if _instanceBlock.size() != count * INSTANCE_STRIDE:
		_instanceBlock.resize(count * INSTANCE_STRIDE)
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var i: int = 0
	for part in parts:
		var angle: float = deg_to_rad(float(int(part["rotation"]) * 90))
		var c: float = cos(angle)
		var s: float = sin(angle)
		# Transform2D(angle, origin) 的 x=(cos,sin)、y=(-sin,cos)
		_instanceBlock[i + 0] = c
		_instanceBlock[i + 1] = -s
		_instanceBlock[i + 2] = 0.0
		var offset: Vector2i = part["offset"]
		_instanceBlock[i + 3] = baseX + float(offset.x) * gridX + halfX
		_instanceBlock[i + 4] = s
		_instanceBlock[i + 5] = c
		_instanceBlock[i + 6] = 0.0
		_instanceBlock[i + 7] = baseY + float(offset.y) * gridY + halfY
		if part["use_color"]:
			# 信号/环路等需要着色的部件，与建筑自身颜色相乘
			var partColor: Color = part["color"]
			_instanceBlock[i + 8] = color.r * partColor.r
			_instanceBlock[i + 9] = color.g * partColor.g
			_instanceBlock[i + 10] = color.b * partColor.b
			_instanceBlock[i + 11] = color.a * partColor.a
		else:
			_instanceBlock[i + 8] = color.r
			_instanceBlock[i + 9] = color.g
			_instanceBlock[i + 10] = color.b
			_instanceBlock[i + 11] = color.a
		var rect: Rect2 = part["rect"]
		_instanceBlock[i + 12] = rect.position.x
		_instanceBlock[i + 13] = rect.position.y
		_instanceBlock[i + 14] = rect.size.x
		_instanceBlock[i + 15] = rect.size.y
		i += INSTANCE_STRIDE
	_blockBaseX = baseX
	_blockBaseY = baseY
	_blockGridX = gridX
	_blockGridY = gridY
	_blockColor = color
	_blockValid = true

# 将本建筑的部件直接写入目标缓冲区（不做跨帧缓存，供手持/阴影等图层使用，避免多线程争用烘培缓存）
# 返回实际写入的实例数量
func writeInstances(target: PackedFloat32Array, startInstance: int, baseX: float, baseY: float, gridX: float, gridY: float, color: Color, maxInstances: int) -> int:
	var parts: Array = getRenderParts()
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var written: int = 0
	for part in parts:
		if startInstance + written >= maxInstances:
			break
		var idx: int = (startInstance + written) * INSTANCE_STRIDE
		var angle: float = deg_to_rad(float(int(part["rotation"]) * 90))
		var c: float = cos(angle)
		var s: float = sin(angle)
		target[idx + 0] = c
		target[idx + 1] = -s
		target[idx + 2] = 0.0
		var offset: Vector2i = part["offset"]
		target[idx + 3] = baseX + float(offset.x) * gridX + halfX
		target[idx + 4] = s
		target[idx + 5] = c
		target[idx + 6] = 0.0
		target[idx + 7] = baseY + float(offset.y) * gridY + halfY
		if part["use_color"]:
			var partColor: Color = part["color"]
			target[idx + 8] = color.r * partColor.r
			target[idx + 9] = color.g * partColor.g
			target[idx + 10] = color.b * partColor.b
			target[idx + 11] = color.a * partColor.a
		else:
			target[idx + 8] = color.r
			target[idx + 9] = color.g
			target[idx + 10] = color.b
			target[idx + 11] = color.a
		var rect: Rect2 = part["rect"]
		target[idx + 12] = rect.position.x
		target[idx + 13] = rect.position.y
		target[idx + 14] = rect.size.x
		target[idx + 15] = rect.size.y
		written += 1
	return written

func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build
func _buildRenderParts() -> Array:
	var out:Array = []
	if buildHasBase:
		#非门等符号在图集中为黑色像素，乘法混色无法变红；改染可着色的灰色底板
		var baseColor:Color = Color()
		var baseUseColor:bool = false
		if buildRef.in_loop:
			baseColor = SwCommon.GetLoopColor()
			baseUseColor = true
		out.append({"rect":buildRef.buildDefine.atlasBuildBase.region,"offset":Vector2i.ZERO,"rotation":0,"color":baseColor,"use_color":baseUseColor})
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		var wire:bool = false
		if buildRef.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
			var pinShowCount = 4
			for pinDir in 4:
				var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(pinDir,null)
				if not net:
					pinShowCount -= 1
			if buildRef.buildState.state != SwDefine.BuildState.HOLDING and pinShowCount!=0:
				wire = true
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var net:SWNet = buildRef.getCircuitCompoent().pinNetMap.get(posmod(p.pin_dir+buildRef.rotation,4),null)
			var color:Color
			var useColor = false
			if net:
				useColor = true
				var wireName:String = ""
				if net.wireGroup == null:
					pass
				else:
					wireName = net.wireGroup.wireName
				var colorArr = SwCommon.GetWireColor(wireName)
				if net.curSignal == SwDefine.CircuitSignal.LOW:
					color = colorArr[0]
				elif net.curSignal == SwDefine.CircuitSignal.HIGH:
					color = colorArr[1]
			elif wire == true:
				continue
			#处于循环依赖中的元件/电线，引脚统一着红色
			if buildRef.in_loop:
				color = SwCommon.GetLoopColor()
				useColor = true
			var r:Rect2 = p.wire_pin.region
			out.append({"rect":r,"offset":p.cell_offset,"rotation":posmod(p.pin_dir+buildRef.rotation,4),"color":color,"use_color":useColor})
	if buildHasAtlas:
		##处于循环依赖中的元件，主体贴图着红色
		var atlasColor:Color = Color()
		var atlasUseColor:bool = false
		#if buildRef.in_loop:
			#atlasColor = SwCommon.GetLoopColor()
			#atlasUseColor = true
		if buildAtlasRotable:
			out.append({"rect":drawRect,"offset":Vector2i.ZERO,"rotation":buildRef.rotation,"color":atlasColor,"use_color":atlasUseColor})
		else:
			out.append({"rect":drawRect,"offset":Vector2i.ZERO,"rotation":0,"color":atlasColor,"use_color":atlasUseColor})
	return out
