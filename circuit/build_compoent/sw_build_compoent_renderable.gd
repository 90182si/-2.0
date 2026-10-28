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
var _geomDirty: bool = true

# ========== 实例数据块缓存 ==========
# 每个部件的 16 个 float 已按 MultiMesh buffer 布局烘培好（含世界坐标、颜色、图集 rect），
# 区块绘制时对整个建筑只需 append_array 一次（一次 C++ memcpy）。
# 上万建筑时这是主要开销：逐实例逐字段的脚本赋值会放大成数百万次数组写入。
# [0]=x.x [1]=y.x [2]=0 [3]=x位移 [4]=x.y [5]=y.y [6]=0 [7]=y位移 [8..11]=颜色 [12..15]=图集rect
const INSTANCE_STRIDE: int = 16
var _instanceBlock: PackedFloat32Array = PackedFloat32Array()
var _geomValid: bool = false
# 烘培时的输入参数，任一变化都需要重新烘培
var _blockBaseX: float = 0.0
var _blockBaseY: float = 0.0
var _blockGridX: float = 0.0
var _blockGridY: float = 0.0

var _colorDirty: bool = true
var _lastMaskColor: Color = Color(-1.0, -1.0, -1.0, -1.0)  # 哨兵：首帧必刷
var _lastInLoop: bool = false
# 上次染色时的图集 LOD 状态：LOD 档连线统一取 high 色，切换档位必须重染一次
var _lastLodMode: bool = false

# 连线类部件的颜色只由所连 net 的电平决定：缓存涉及的 net（按对象去重），
# 区块重绘时比对 net 的电平版本号，翻转了才重刷颜色。
# 这样一根线翻转不需要在电路层逐根打脏（连线数量是门的十几倍）
var _colorNets: Array[SWNet] = []
var _lastSigVersion: int = -1

# 电线A/电线B：连线颜色用建筑自身线别。一个 net 里可能混接两线别，
# net.wireGroup.wireName 只会记下最后一个写入者，不能作为 A/B 的取色依据。
var _ownPalette: bool = false
var _ownColorLow: Color = Color.WHITE
var _ownColorHigh: Color = Color.WHITE
# 分组键：用自身线别时取线名（电线A/电线B 各自一组），跟随 net 时为空串
var _paletteKey: String = ""

# 图集帧切换（开关/灯/寄存器等换贴图）只改 atlas 部件的 rect，
# 不重建部件与几何。图集部件在 _buildRenderParts 中总是最后追加。
var _atlasRectDirty: bool = false
var _atlasPartIndex: int = -1

func markRenderPartsDirty() -> void:
	_geomDirty = true
	_geomValid = false

func markColorDirty() -> void:
	_colorDirty = true
	pass

func markAtlasRectDirty() -> void:
	_atlasRectDirty = true

# 把本建筑「随 net 电平变色」的实例颜色列登记进区块的批量索引。
# startInstance 是本建筑在区块 buffer 中的起始实例下标，部件顺序与 getRenderParts 一致。
# entries 按 net+调色板分组；index 是本次区块构建期的去重表（net -> {调色板键: 条目}）。
func registerNetColumns(startInstance: int, entries: Array, index: Dictionary) -> void:
	#环路色覆盖整栋建筑，与 net 电平无关，不参与批量换色；预览建筑不挂电路
	if buildRef.in_loop or buildRef.is_preview:
		return
	var parts: Array = getRenderParts()
	var cir: SWBuildCompoentCircuit = buildRef.getCircuitCompoent()
	if cir == null:
		return
	var mask: Color = buildRef.buildState.mask_color
	var isWhite: bool = mask == Color.WHITE
	var col: int = startInstance * INSTANCE_STRIDE + 8
	for part in parts:
		if part.has("pin_dir"):
			var net: SWNet = cir.pinNetMap.get(part["pin_dir"], null)
			if net != null:
				var e: SWNetColorEntry = _netEntryFor(entries, index, net)
				if isWhite:
					e.cols.append(col)
				else:
					e.mask_cols.append(col)
					e.mask_colors.append(mask)
		col += INSTANCE_STRIDE

func _netEntryFor(entries: Array, index: Dictionary, net: SWNet) -> SWNetColorEntry:
	var byPalette: Dictionary = index.get(net, {})
	var e: SWNetColorEntry = byPalette.get(_paletteKey, null)
	if e != null:
		return e
	e = SWNetColorEntry.new()
	e.net = net
	e.is_own = _ownPalette
	if _ownPalette:
		e.low = _ownColorLow
		e.high = _ownColorHigh
	else:
		_resolveNetColor(net)
		e.low = net.renderColorLow
		e.high = net.renderColorHigh
	byPalette[_paletteKey] = e
	index[net] = byPalette
	entries.append(e)
	return e

func getRenderParts() -> Array:
	if not _geomDirty:
		return _renderPartsCache
	_renderPartsCache = _buildRenderParts()
	_geomDirty = false
	_geomValid = false
	return _renderPartsCache

# 获取整块实例数据：世界坐标/颜色/图集均已烘培，参数未变时零计算直接复用
# applyColor=false 用于 LOD 降级：只取几何与图集帧，跳过电平颜色重算。
# 此时 _colorDirty / _lastSigVersion 都不动，下次带颜色的调用会把冻结期间的变化一次补齐。
func getInstanceBlock(baseX: float, baseY: float, gridX: float, gridY: float, maskColor:Color, applyColor:bool = true) -> PackedFloat32Array:
	if not _geomValid or _geomDirty or _blockBaseX != baseX or _blockBaseY != baseY \
			or _blockGridX != gridX or _blockGridY != gridY:
		_bakeGeometry(baseX, baseY, gridX, gridY)
	# 图集帧变化：只回写该实例的 rect，几何/部件保持不动
	# parts 快照可能被其他线程持有，按只读约定不原地改字典；图集 rect 的真源是 drawRect
	if _atlasRectDirty:
		_atlasRectDirty = false
		if _atlasPartIndex >= 0 and _atlasPartIndex < _renderPartsCache.size():
			var ai: int = _atlasPartIndex * INSTANCE_STRIDE
			var r: Rect2 = drawRect
			_instanceBlock[ai + 12] = r.position.x
			_instanceBlock[ai + 13] = r.position.y
			_instanceBlock[ai + 14] = r.size.x
			_instanceBlock[ai + 15] = r.size.y
	if not applyColor:
		return _instanceBlock
	# 只有本拍颜色可能变化的建筑才重算；其余直接复用上次烘好的颜色
	var sigVersion: int = _netSigVersion()
	var lodMode: bool = SwAtlas.is_lod_active()
	if _colorDirty or sigVersion != _lastSigVersion \
			or maskColor != _lastMaskColor or buildRef.in_loop != _lastInLoop \
			or lodMode != _lastLodMode:
		_applyColors(maskColor)
		_lastMaskColor = maskColor
		_lastInLoop = buildRef.in_loop
		_lastSigVersion = sigVersion
		_lastLodMode = lodMode
		_colorDirty = false
	return _instanceBlock

# 所连 net 的电平版本指纹：任一 net 翻转都会让它变化
func _netSigVersion() -> int:
	if _colorNets.is_empty():
		return 0
	var v: int = 0
	for net in _colorNets:
		v = v * 31 + net.sigVersion
	return v

func _resolveNetColor(net: SWNet) -> void:
	if net.renderColorResolved:
		return
	var wireName: String = net.wireGroup.wireName if net.wireGroup != null else ""
	var arr: Array[Color] = SwCommon.GetWireColor(wireName)
	net.renderColorLow = arr[0]
	net.renderColorHigh = arr[1]
	net.renderColorResolved = true

# 连线部件取色：电线A/B 用自身线别调色板，其余（门/灯/按钮/桥梁/隧道）沿用所属 net。
# 图集 LOD 档位下统一取 high 色，避免缩远时整屏连线随电路闪烁，颜色在此期间也不再跟随电路
func _pinColor(net: SWNet) -> Color:
	if _ownPalette:
		if SwAtlas.is_lod_active():
			return _ownColorHigh
		return _ownColorHigh if net.curSignal == SwDefine.CircuitSignal.HIGH else _ownColorLow
	_resolveNetColor(net)
	if SwAtlas.is_lod_active():
		return net.renderColorHigh
	return net.renderColorHigh if net.curSignal == SwDefine.CircuitSignal.HIGH else net.renderColorLow

func _applyColors(maskColor: Color) -> void:
	var inLoop: bool = buildRef.in_loop
	var loopColor: Color = SwCommon.GetLoopColor() if inLoop else Color()
	#预览建筑没有电路组件，整栋按底色绘制
	var cir: SWBuildCompoentCircuit = null
	if not buildRef.is_preview:
		cir = buildRef.getCircuitCompoent()
	var i: int = 8
	for part in _renderPartsCache:
		var c: Color = maskColor
		if inLoop and part["loop_tint"]:
			c = maskColor * loopColor
		elif cir != null and part.has("pin_dir"):
			var net: SWNet = cir.pinNetMap.get(part["pin_dir"], null)   # 活引用，不靠缓存
			if net != null:
				c = maskColor * _pinColor(net)
		_instanceBlock[i + 0] = c.r
		_instanceBlock[i + 1] = c.g
		_instanceBlock[i + 2] = c.b
		_instanceBlock[i + 3] = c.a
		i += INSTANCE_STRIDE
		
# 部件数量（不需要构建数据块）
func getRenderPartCount() -> int:
	return getRenderParts().size()

# 将部件列表烘培成可被 MultiMesh buffer 直接追加的扁平数组
func _bakeGeometry(baseX: float, baseY: float, gridX: float, gridY: float) -> void:
	var parts: Array = getRenderParts()
	var count: int = parts.size()
	if _instanceBlock.size() != count * INSTANCE_STRIDE:
		_instanceBlock.resize(count * INSTANCE_STRIDE)
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var i: int = 0
	var partIdx: int = 0
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
		var rect: Rect2 = drawRect if partIdx == _atlasPartIndex else part["rect"]
		_instanceBlock[i + 12] = rect.position.x
		_instanceBlock[i + 13] = rect.position.y
		_instanceBlock[i + 14] = rect.size.x
		_instanceBlock[i + 15] = rect.size.y
		i += INSTANCE_STRIDE
		partIdx += 1
	_blockBaseX = baseX
	_blockBaseY = baseY
	_blockGridX = gridX
	_blockGridY = gridY
	#_blockColor = color
	_geomValid = true
	_colorDirty = true

# 将本建筑的部件直接写入目标缓冲区（不做跨帧缓存，供手持/阴影等图层使用，避免多线程争用烘培缓存）
# 返回实际写入的实例数量
func writeInstances(target: PackedFloat32Array, startInstance: int, baseX: float, baseY: float, gridX: float, gridY: float, color: Color, maxInstances: int) -> int:
	var parts: Array = getRenderParts()
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var inLoop: bool = buildRef.in_loop
	var loopColor: Color = SwCommon.GetLoopColor() if inLoop else Color()
	var cir: SWBuildCompoentCircuit = null
	if not buildRef.is_preview:
		cir = buildRef.getCircuitCompoent()
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
		var col: Color = color
		if inLoop and part["loop_tint"]:
			col = color * loopColor
		elif cir != null and part.has("pin_dir"):
			var net: SWNet = cir.pinNetMap.get(part["pin_dir"], null)
			if net != null:
				col = color * _pinColor(net)
		target[idx + 8] = col.r
		target[idx + 9] = col.g
		target[idx + 10] = col.b
		target[idx + 11] = col.a
		var rect: Rect2 = drawRect if written == _atlasPartIndex else part["rect"]
		target[idx + 12] = rect.position.x
		target[idx + 13] = rect.position.y
		target[idx + 14] = rect.size.x
		target[idx + 15] = rect.size.y
		written += 1
	return written

func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build
	_ownPalette = false
	_paletteKey = ""
	if build != null and build.buildDefine != null \
			and build.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
		_ownPalette = true
		_paletteKey = build.buildDefine.buildName
		var arr: Array[Color] = SwCommon.GetWireColor(build.buildDefine.buildName)
		_ownColorLow = arr[0]
		_ownColorHigh = arr[1]
func _buildRenderParts() -> Array:
	var out:Array = []
	if buildHasBase:
		#非门等符号在图集中为黑色像素，乘法混色无法变红；改染可着色的灰色底板
		var baseColor:Color = Color()
		var baseUseColor:bool = false
		if buildRef.in_loop:
			baseColor = SwCommon.GetLoopColor()
			baseUseColor = true
		out.append({
			"rect":buildRef.buildDefine.atlasBuildBase.region,
			"offset":Vector2i.ZERO,
			"rotation":0,
			"use_color":false,
			"loop_tint":true,
			"color_low":Color(),
			"color_high":Color(),
			"net":null
		})
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		#预览建筑不挂电路：所有端口都按无 net 处理，也不去取电路组件
		var cir: SWBuildCompoentCircuit = null
		if not buildRef.is_preview:
			cir = buildRef.getCircuitCompoent()
		var wire:bool = false
		if buildRef.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
			var pinShowCount = 4
			for pinDir in 4:
				var net:SWNet = cir.pinNetMap.get(pinDir,null) if cir != null else null
				if not net:
					pinShowCount -= 1
			if buildRef.buildState.state != SwDefine.BuildState.HOLDING and pinShowCount!=0:
				wire = true
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var net:SWNet = cir.pinNetMap.get(posmod(p.pin_dir+buildRef.rotation,4),null) if cir != null else null
			var useColor = false
			var colorLow:Color = Color()
			var colorHigh:Color = Color()
			if net:
				useColor = true
				var wireName:String = ""
				if net.wireGroup != null:
					wireName = net.wireGroup.wireName
				var colorArr = SwCommon.GetWireColor(wireName)
				colorLow = colorArr[0]
				colorHigh = colorArr[1]
			elif wire == true:
				continue
			out.append({
				"rect":p.wire_pin.region,
				"offset":p.cell_offset,
				"rotation":posmod(p.pin_dir+buildRef.rotation,4),
				"pin_dir":posmod(p.pin_dir+buildRef.rotation,4),   # ← 新增：世界方向，供 _applyColors 现取 net
				"use_color":useColor,
				"loop_tint":true,
				"color_low":colorLow,
				"color_high":colorHigh,
				"net":net
			})	
	if buildHasAtlas:
		if buildAtlasRotable:
			out.append({
				"rect":drawRect,
				"offset":Vector2i.ZERO,
				"rotation":buildRef.rotation,
				"use_color":false,
				"loop_tint":false,
				"color_low":Color(),
				"color_high":Color(),
				"net":null
			})
		else:
			out.append({
				"rect":drawRect,
				"offset":Vector2i.ZERO,
				"rotation":0,
				"use_color":false,
				"loop_tint":false,
				"color_low":Color(),
				"color_high":Color(),
				"net":null
			})
		_atlasPartIndex = out.size() - 1
	else:
		_atlasPartIndex = -1
	#收集本建筑着色部件涉及的 net（同一 net 只存一次），供重绘时比对比电平版本
	_colorNets.clear()
	_lastSigVersion = -1
	for part in out:
		if not part.has("pin_dir"):
			continue
		var net:SWNet = part["net"]
		if net != null and not _colorNets.has(net):
			_colorNets.append(net)
	return out
