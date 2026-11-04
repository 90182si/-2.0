class_name SWBuildCompoentRenderable extends SWBuildCompoent
	
var buildRef:SWBuildItemDefine = null
var buildHasBase:bool = false
var buildHasAtlas:bool = false
var buildAtlasRotable:bool = true
var drawRect:Rect2

# ========== 渲染部件缓存（平行 PackedArray，替代 Dictionary 数组） ==========
# 原 Dictionary 数组每部件容器开销 ~500 bytes（9 个 string key + 哈希表），
# 16万建筑 × 4 部件 ≈ 350MB 纯容器。改成平行 PackedArray 后每部件仅 ~28 bytes 数据。
# 布局：_partRect[i*4+0..3] = (x,y,w,h)；_partOff[i*2+0..1] = (ox,oy)；
#       _partRot[i] = 0-3；_partPinDir[i] = -1(无pin) 或 0-3(世界方向)；
#       _partLoopTint[i] = 0/1；_partNet[i] = SWNet 引用或 null。
var _partRect: PackedFloat32Array = PackedFloat32Array()
var _partOff: PackedInt32Array = PackedInt32Array()
var _partRot: PackedInt32Array = PackedInt32Array()
var _partPinDir: PackedInt32Array = PackedInt32Array()
var _partLoopTint: PackedByteArray = PackedByteArray()
var _partNet: Array = []
var _geomDirty: bool = true

# ========== 实例数据块缓存 ==========
# 每个部件的 16 个 float 已按 MultiMesh buffer 布局烘培好（含世界坐标、tint、style/net/palette 索引），
# 区块绘制时对整个建筑只需 append_array 一次（一次 C++ memcpy）。
# 上万建筑时这是主要开销：逐实例逐字段的脚本赋值会放大成数百万次数组写入。
# [0]=x.x [1]=y.x [2]=0 [3]=x位移 [4]=x.y [5]=y.y [6]=0 [7]=y位移
# [8..11]=tint（白/选中底色/环路警示；信号色由 shader 从纹理绝对驱动，不再乘进这里）
# [12..15]=[style_id, net_id, palette_id, flags]（图集 rect 改存 styleTex 索引，运行时信号翻转零写入）
const INSTANCE_STRIDE: int = 16

# ========== 缩远简化（LOD）缓存 ==========
# _instanceBlockLod：简化档的实例块（只含主体部件，1 个实例）
# _blockLodValid   ：当前简化档缓存对应的 lod 档位（-1 = 无效，需重烘）
var _instanceBlockLod: PackedFloat32Array = PackedFloat32Array()
var _blockLodValid: int = -1
var _instanceBlock: PackedFloat32Array = PackedFloat32Array()
var _geomValid: bool = false
# 烘培时的输入参数，任一变化都需要重新烘培
var _blockBaseX: float = 0.0
var _blockBaseY: float = 0.0
var _blockGridX: float = 0.0
var _blockGridY: float = 0.0
# 环路状态也参与烘培（loop 警示部件的 net_id 要置 -1 不采样信号），变化需重烘培
var _lastBakeInLoop: bool = false

var _colorDirty: bool = true
var _lastMaskColor: Color = Color(-1.0, -1.0, -1.0, -1.0)  # 哨兵：首帧必刷
var _lastInLoop: bool = false

# 图集帧切换（开关/灯/寄存器等换贴图）：纹理化后帧切换 shader 化——
# 帧对 (off,on) 惰性登记进 styleTex，帧选择电平写入信号纹理「帧槽」，
# 实例缓冲零写入。markAtlasRectDirty 保留为 no-op 兼容旧调用。
var _atlasRectDirty: bool = false
var _atlasPartIndex: int = -1
# 帧状态（LED/寄存器/非门/按钮的亮灭）：信号纹理帧槽索引与当前状态。
# 烘焙时分配帧槽；setFrameState 只写纹理，不再回写实例缓冲。
var _frameSlot: int = -1
var _frameHigh: bool = false

func _is_frame_build() -> bool:
	return buildRef != null and (buildRef is SWBuildLed or buildRef is SWBuildRegister1Bit \
			or buildRef is SWBuildNot or buildRef is SWBuildButton)

# 帧状态写入信号纹理帧槽（shader 据此选图集帧 on/off）。烘焙前调用只记录状态，
# 首次烘焙分配帧槽后立即补写，防首帧显示旧电平。
#
# 性能（64x 存档读档卡顿治理）：一次求值里同一组件会被反复触达，而 set_level 每次都要
# 走 SWSignalTextureGPU.instance 单例 getter（很贵）。求值期间把写入交给
# SWCircuitControl.submitFrameState 按拍合并，同一帧槽一拍只写一次。
func setFrameState(high: bool) -> void:
	_frameHigh = high
	if _frameSlot < 0:
		return
	var ctrl := _frameOwner()
	if ctrl != null:
		ctrl.submitFrameState(_frameSlot, high)
		return
	var tex := SWSignalTexture.instance
	if tex != null:
		tex.set_level(_frameSlot, high)

# 找到当前求值轮的电路控制（未在求值中则返回 null，调用方直接写纹理）
func _frameOwner() -> SWCircuitControl:
	if buildRef == null:
		return null
	var cir: SwDefine.SWCircuitData = buildRef.circuit
	if cir == null:
		return null
	return _activeOwner

# 当前正在求值的 SWCircuitControl（求值开始时由控制方设置，结束时清空）。
# 用静态变量而非逐建筑回溯 circuit->owner，省掉每组件一次对象跳转。
static var _activeOwner: SWCircuitControl = null

func markRenderPartsDirty() -> void:
	_geomDirty = true
	_geomValid = false

func markColorDirty() -> void:
	_colorDirty = true
	pass

func markAtlasRectDirty() -> void:
	# 图集帧已由 styleTex 索引静态决定：换帧需要改 drawRect 并整块重建（markRenderPartsDirty）。
	# 保留接口兼容旧调用，不再做实例级 rect 回写。
	pass

# 部件数量
func _partCount() -> int:
	return _partRect.size() >> 2

# 兼容旧调用：返回部件数量（外部曾用 getRenderParts().size()）
func getRenderPartCount() -> int:
	_ensureParts()
	return _partCount()

# 确保平行数组已构建（懒触发）
func _ensureParts() -> void:
	if _geomDirty:
		_buildRenderParts()
		_geomDirty = false
		_geomValid = false

# 获取整块实例数据：世界坐标/tint/索引均已烘培，参数未变时零计算直接复用
# applyColor 参数保留兼容旧调用（LOD 冻结改由 shader signalFrozen 处理，不再影响 tint 烘焙）。
#
# lod（缩远简化，见 SWDrawManager.on_view_rect_changed）：
#   0/1 = 满精度，返回全部部件（主体 + 底板 + 端子）
#   2   = 只保留「主体」部件（丢掉底板与端子）
#   3   = 只保留「主体」部件，且跳过纯装饰（信号为空的端子在这里已经没了）
# 缩远时一个建筑格只有几个像素，端子/底板都是亚像素点，丢掉后视觉几乎无损，
# 但实例数能降 2~5 倍 —— 这是「越缩越卡」的主要解法。
# _instanceBlockLod 缓存按 LOD 分档保存，切档时才重烘，同一档内零计算。
func getInstanceBlock(baseX: float, baseY: float, gridX: float, gridY: float,
		maskColor:Color, applyColor:bool = true, lod:int = 0) -> PackedFloat32Array:
	# 手持预览克隆不进 ByContent 图层（它走 ByHold/HoldShadow 的 writeInstances 直写），
	# 直接短路，跳过 _instanceBlock 烘焙与颜色重算，省掉每克隆 300+ bytes 的 PackedFloat32Array
	if buildRef != null and buildRef.is_preview:
		return PackedFloat32Array()
	if not _geomValid or _geomDirty or _blockBaseX != baseX or _blockBaseY != baseY \
			or _blockGridX != gridX or _blockGridY != gridY or buildRef.in_loop != _lastBakeInLoop:
		_bakeGeometry(baseX, baseY, gridX, gridY)
		# 几何重烘后所有 LOD 档缓存都失效
		_blockLodValid = -1
	# tint 只由选中底色与环路警示决定（信号色在 shader 采样），与电平版本/LOD 无关。
	# 必须在取简化档之前染：_bakeSimplified 是从 _instanceBlock 切片的，把它留在 lod 分支之后
	# 就永远不执行 —— 新建筑带着 resize 出来的全 0 tint（alpha=0）上屏，表现为
	# 「缩到 LOD 简化档后复制粘贴的电路完全看不见，放大并重进视野才出来」。
	if _colorDirty or maskColor != _lastMaskColor or buildRef.in_loop != _lastInLoop:
		_applyColors(maskColor)
		_lastMaskColor = maskColor
		_lastInLoop = buildRef.in_loop
		_colorDirty = false
		# 切片里的 tint 跟着过期，作废重切
		_blockLodValid = -1
	# 缩远简化档：只烘「主体」部件
	if lod >= LOD_SIMPLIFY_LEVEL:
		# 先染 tint 再切片：_bakeSimplified 从 _instanceBlock 拷 16 个 float，其中 8..11 是 tint。
		# 染色段原本排在下面这个 return 之后，所以新建筑第一次就以简化档取块时拿到的是
		# resize 出来的全 0 tint（alpha=0），上屏后完全透明 —— 这就是「缩到 LOD 简化档后
		# 复制粘贴的电路永远不显示，放大并重进视野才出来」的根因。
		if _colorDirty or maskColor != _lastMaskColor or buildRef.in_loop != _lastInLoop:
			_applyColors(maskColor)
			_lastMaskColor = maskColor
			_lastInLoop = buildRef.in_loop
			_colorDirty = false
			_blockLodValid = -1
		if _blockLodValid != lod:
			_bakeSimplified(lod)
			_blockLodValid = lod
		return _instanceBlockLod
	return _instanceBlock

# 缩远简化档阈值：>= 该值只画主体部件
const LOD_SIMPLIFY_LEVEL: int = 2

# 简化档烘焙：只取「主体」那一件（atlas 部件），没有主体时退回第一件。
# 复用已烘好的 _instanceBlock，按 INSTANCE_STRIDE 切片拷贝，避免重算世界坐标。
func _bakeSimplified(_lod: int) -> void:
	var count: int = _partCount()
	var keep: int = _atlasPartIndex
	if keep < 0 or keep >= count:
		keep = count - 1
	if keep < 0:
		_instanceBlockLod = PackedFloat32Array()
		return
	var start: int = keep * INSTANCE_STRIDE
	if _instanceBlock.size() < start + INSTANCE_STRIDE:
		_instanceBlockLod = PackedFloat32Array()
		return
	_instanceBlockLod = _instanceBlock.slice(start, start + INSTANCE_STRIDE)

# 端子/底座/主体的 tint：maskColor（白/选中）乘环路警示色；信号色由 shader 从调色板纹理绝对驱动，
# 这里不再乘任何绝对色（否则与 signalTex 双重乘法，历史 bug）。
func _applyColors(maskColor: Color) -> void:
	var inLoop: bool = buildRef.in_loop
	var loopColor: Color = SwCommon.GetLoopColor() if inLoop else Color()
	var i: int = 8
	var n: int = _partCount()
	for j in n:
		var c: Color = maskColor
		if inLoop and _partLoopTint[j] != 0:
			c = maskColor * loopColor
		_instanceBlock[i + 0] = c.r
		_instanceBlock[i + 1] = c.g
		_instanceBlock[i + 2] = c.b
		_instanceBlock[i + 3] = c.a
		i += INSTANCE_STRIDE

# 将部件列表烘培成可被 MultiMesh buffer 直接追加的扁平数组
func _bakeGeometry(baseX: float, baseY: float, gridX: float, gridY: float) -> void:
	_ensureParts()
	var count: int = _partCount()
	if _instanceBlock.size() != count * INSTANCE_STRIDE:
		_instanceBlock.resize(count * INSTANCE_STRIDE)
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var inLoopNow: bool = buildRef.in_loop
	var styleTex: SWStyleTexture = SWStyleTexture.instance
	var i: int = 0
	for partIdx in count:
		var angle: float = deg_to_rad(float(_partRot[partIdx] * 90))
		var c: float = cos(angle)
		var s: float = sin(angle)
		# Transform2D(angle, origin) 的 x=(cos,sin)、y=(-sin,cos)
		_instanceBlock[i + 0] = c
		_instanceBlock[i + 1] = -s
		_instanceBlock[i + 2] = 0.0
		var ox: int = _partOff[partIdx * 2]
		var oy: int = _partOff[partIdx * 2 + 1]
		_instanceBlock[i + 3] = baseX + float(ox) * gridX + halfX
		_instanceBlock[i + 4] = s
		_instanceBlock[i + 5] = c
		_instanceBlock[i + 6] = 0.0
		_instanceBlock[i + 7] = baseY + float(oy) * gridY + halfY
		var styleId: int = -1
		var netId: float = -1.0
		var palId: float = 0.0
		var flags: float = 0.0
		if partIdx == _atlasPartIndex and _is_frame_build():
			# 帧建筑（LED/寄存器/非门/按钮）：帧切换 shader 化。
			# styleTex 登记 (off, on) 帧对；帧选择电平写入信号纹理帧槽，实例缓冲零写入。
			var frameOff: Rect2 = buildRef.buildDefine.atlasTextureOff.region
			var frameOn: Rect2 = frameOff
			if buildRef.buildDefine.atlasTextureOn != null:
				frameOn = buildRef.buildDefine.atlasTextureOn.region
			styleId = styleTex.register_frame(frameOff, frameOn)
			var tex := SWSignalTexture.instance
			if _frameSlot < 0 and tex != null:
				_frameSlot = tex.alloc_frame_slot()
				# 求值可能先于首烘：烘焙时立即把已定状态写入帧槽
				tex.set_level(_frameSlot, _frameHigh)
			if _frameSlot >= 0:
				netId = float(_frameSlot)
			flags = 1.0
		else:
			var rect: Rect2
			if partIdx == _atlasPartIndex:
				rect = drawRect
			else:
				rect = Rect2(_partRect[partIdx*4], _partRect[partIdx*4+1],
						_partRect[partIdx*4+2], _partRect[partIdx*4+3])
			# style_id 惰性登记（未登记 rect 自动扩容纹理，绝不出品红哨兵）
			styleId = styleTex.register_rect(rect)
			var net: SWNet = _partNet[partIdx]
			if net != null:
				# 环路警示部件不采样信号：net_id=-1 使 shader 跳过调色板，纯 tint 显示
				if not (inLoopNow and _partLoopTint[partIdx] != 0):
					netId = float(net.netId)
					palId = float(net.paletteId)
		_instanceBlock[i + 12] = float(styleId)
		_instanceBlock[i + 13] = netId
		_instanceBlock[i + 14] = palId
		_instanceBlock[i + 15] = flags
		i += INSTANCE_STRIDE
	_blockBaseX = baseX
	_blockBaseY = baseY
	_blockGridX = gridX
	_blockGridY = gridY
	_lastBakeInLoop = inLoopNow
	_geomValid = true
	_colorDirty = true

# 将本建筑的部件直接写入目标缓冲区（不做跨帧缓存，供手持/阴影等图层使用，避免多线程争用烘培缓存）
# 返回实际写入的实例数量
func writeInstances(target: PackedFloat32Array, startInstance: int, baseX: float, baseY: float, gridX: float, gridY: float, color: Color, maxInstances: int) -> int:
	_ensureParts()
	var halfX: float = gridX * 0.5
	var halfY: float = gridY * 0.5
	var inLoop: bool = buildRef.in_loop
	var loopColor: Color = SwCommon.GetLoopColor() if inLoop else Color()
	var styleTex: SWStyleTexture = SWStyleTexture.instance
	var written: int = 0
	var n: int = _partCount()
	for j in n:
		if startInstance + written >= maxInstances:
			break
		var idx: int = (startInstance + written) * INSTANCE_STRIDE
		var angle: float = deg_to_rad(float(_partRot[j] * 90))
		var c: float = cos(angle)
		var s: float = sin(angle)
		target[idx + 0] = c
		target[idx + 1] = -s
		target[idx + 2] = 0.0
		var ox: int = _partOff[j * 2]
		var oy: int = _partOff[j * 2 + 1]
		target[idx + 3] = baseX + float(ox) * gridX + halfX
		target[idx + 4] = s
		target[idx + 5] = c
		target[idx + 6] = 0.0
		target[idx + 7] = baseY + float(oy) * gridY + halfY
		var col: Color = color
		if inLoop and _partLoopTint[j] != 0:
			col = color * loopColor
		target[idx + 8] = col.r
		target[idx + 9] = col.g
		target[idx + 10] = col.b
		target[idx + 11] = col.a
		var styleId: int = -1
		var netId: float = -1.0
		var palId: float = 0.0
		var flags: float = 0.0
		if j == _atlasPartIndex and _is_frame_build():
			# 帧建筑：帧对 + 帧槽（与 _bakeGeometry 一致）
			var frameOff: Rect2 = buildRef.buildDefine.atlasTextureOff.region
			var frameOn: Rect2 = frameOff
			if buildRef.buildDefine.atlasTextureOn != null:
				frameOn = buildRef.buildDefine.atlasTextureOn.region
			styleId = styleTex.register_frame(frameOff, frameOn)
			var tex := SWSignalTexture.instance
			if _frameSlot < 0 and tex != null:
				_frameSlot = tex.alloc_frame_slot()
				tex.set_level(_frameSlot, _frameHigh)
			if _frameSlot >= 0:
				netId = float(_frameSlot)
			flags = 1.0
		else:
			var rect: Rect2
			if j == _atlasPartIndex:
				rect = drawRect
			else:
				rect = Rect2(_partRect[j*4], _partRect[j*4+1],
						_partRect[j*4+2], _partRect[j*4+3])
			styleId = styleTex.register_rect(rect)
			var net: SWNet = _partNet[j]
			if net != null:
				if not (inLoop and _partLoopTint[j] != 0):
					netId = float(net.netId)
					palId = float(net.paletteId)
		target[idx + 12] = float(styleId)
		target[idx + 13] = netId
		target[idx + 14] = palId
		target[idx + 15] = flags
		written += 1
	return written

func setBuildRef(build:SWBuildItemDefine) -> void:
	buildRef = build

# 追加一个部件到平行数组
func _appendPart(rect: Rect2, offset: Vector2i, rotation: int, pinDir: int, loopTint: bool, net: SWNet) -> void:
	_partRect.append(rect.position.x)
	_partRect.append(rect.position.y)
	_partRect.append(rect.size.x)
	_partRect.append(rect.size.y)
	_partOff.append(offset.x)
	_partOff.append(offset.y)
	_partRot.append(rotation)
	_partPinDir.append(pinDir)   # -1 = 无 pin
	_partLoopTint.append(1 if loopTint else 0)
	_partNet.append(net)

func _buildRenderParts() -> void:
	# 清空旧平行数组
	_partRect.resize(0)
	_partOff.resize(0)
	_partRot.resize(0)
	_partPinDir.resize(0)
	_partLoopTint.resize(0)
	_partNet.resize(0)

	if buildHasBase:
		#非门等符号在图集中为黑色像素，乘法混色无法变红；改染可着色的灰色底板
		_appendPart(buildRef.buildDefine.atlasBuildBase.region, Vector2i.ZERO, 0, -1, true, null)
	if buildRef.buildDefine and buildRef.buildDefine.build_pin.size() > 0:
		#预览建筑不挂电路：所有端口都按无 net 处理，也不去取电路组件
		var cir: SWBuildCompoentCircuit = null
		if not buildRef.is_preview:
			cir = buildRef.getCircuitCompoent()
		var wire:bool = false
		if buildRef.buildDefine.circuit_component_type == SwDefine.CircuitComponentType.WIRE:
			var pinShowCount = 4
			for pinDir in 4:
				var net0:SWNet = cir.pinNetMap.get(pinDir,null) if cir != null else null
				if not net0:
					pinShowCount -= 1
			if buildRef.buildState.state != SwDefine.BuildState.HOLDING and pinShowCount!=0:
				wire = true
		for p:SWBuildPinDefine in buildRef.buildDefine.build_pin:
			var net:SWNet = cir.pinNetMap.get(posmod(p.pin_dir+buildRef.rotation,4),null) if cir != null else null
			if net == null and wire:
				continue
			# pin_dir 存世界方向，供烘焙时现取 net
			_appendPart(p.wire_pin.region, p.cell_offset,
					posmod(p.pin_dir+buildRef.rotation,4),
					posmod(p.pin_dir+buildRef.rotation,4),
					true, net)
	if buildHasAtlas:
		var rot: int = buildRef.rotation if buildAtlasRotable else 0
		_appendPart(drawRect, Vector2i.ZERO, rot, -1, false, null)
		_atlasPartIndex = _partCount() - 1
	else:
		_atlasPartIndex = -1
