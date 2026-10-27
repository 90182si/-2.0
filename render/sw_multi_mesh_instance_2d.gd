class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

var _swTransform:SwDefine.SWTransformData
var _gridSize:Vector2 = SwDefine.GRID_SIZE
# QuadMesh 尺寸是否已按 _gridSize 设置过（软缓存复用节点时尺寸不变则跳过）
var _meshSizeInited:bool = false
var _drawMode:SwDefine.GridDrawMode=SwDefine.GridDrawMode.Tiling

# 地图平铺（Tiling）专用缓冲：整块铺满 CHUNK_SIZE×CHUNK_SIZE 个格子
var buffer:PackedFloat32Array

# 平铺层只构建一次：内容不会变，避免每帧重算
var _hadDraw:bool = false
var _gridSizeTmp:Vector2 = Vector2.ZERO

# 上次绘制时的建筑内容版本号：内容未变时可直接复用 MultiMesh 中已有的 buffer
var builtVersion:int = -1
var e = Vector2i(SwDefine.CHUNK_SIZE, SwDefine.CHUNK_SIZE)
var n = e.x*e.y	
var maxInstances:int = 0   #含部件叠加后的最大实例容量

# ========== 内容层持久缓冲 ==========
# 所有绘制都在主线程完成：没有工作线程，也就没有跨线程共享与 buffer 快照开销。
# _cpuBuffer 常驻，按实例排布（16 floats/实例）；_slotStart/_slotParts 记录每个建筑
# 占用的实例区间，信号翻转时只回写这些建筑的 8..15 列（颜色/图集 rect），
# 不必把整块 256 个建筑的部件与几何重新生成一遍。
var _cpuBuffer: PackedFloat32Array = PackedFloat32Array()
var _slotStart: Dictionary = {}   # SWBuildItemDefine -> 起始实例下标
var _slotParts: Dictionary = {}   # SWBuildItemDefine -> 实例数
var _usedInstances: int = 0
var _slotsValid: bool = false
# ========== 连线色批量索引 ==========
# 一根 net 翻转时它挂着的所有连线都要换色；上万根线逐建筑补丁会退化成上万次脚本调用。
# 这里把「net -> 本区块内相关实例的颜色列偏移」预先摊平，翻转时一次算色、
# 顺序写 4 个分量，把开销压回纯内存写。
var _netCols: Dictionary = {}     # SWNet -> PackedInt32Array（每项 = 实例下标*16+8，白底）
var _netMaskCols: Dictionary = {} # SWNet -> PackedInt32Array（带底色，如选中高亮）
var _netMaskColors: Dictionary = {} # SWNet -> PackedColorArray（与 _netMaskCols 同序）
# 临时诊断计数（性能探针读取）
static var dbg_net_checks: int = 0
static var dbg_cols_written: int = 0
static var dbg_uploads: int = 0
static var dbg_floats_uploaded: int = 0

func _init() -> void:
	_swTransform = SwDefine.SWTransformData.new()
	n = e.x * e.y
	maxInstances = n * SwDefine.MAX_RENDER_PARTS
	if multimesh:
		# 启用颜色支持（如果需要）
		multimesh.use_colors = true
		# 实例容量按实际用量调整（见 _upload）
		multimesh.instance_count = 1

func _ready() -> void:
	# 运行前从全局配置 SwAtlas 取当前图集，覆盖 shader 采样用的 srcImg
	# material 是场景子资源，被所有区块节点共享：参数已一致时必须跳过，
	# 否则每新增一个区块都会触发一次全量材质更新（区块越多越慢）
	var mat := material as ShaderMaterial
	if mat and SwAtlas.current and mat.get_shader_parameter("srcImg") != SwAtlas.current:
		mat.set_shader_parameter("srcImg", SwAtlas.current)
		
func setDrawMode(mode:SwDefine.GridDrawMode) -> void:
	_drawMode = mode
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		z_index = -100
	elif _drawMode == SwDefine.GridDrawMode.ByContent:
		z_index = 0
	elif _drawMode == SwDefine.GridDrawMode.HoldShadow:
		z_index = 50
	elif _drawMode == SwDefine.GridDrawMode.ByHold:
		z_index = 100
		
func resetOffsetAndScale(_swTf:SwDefine.SWTransformData) -> void:
	_swTransform = _swTf
	position = _swTransform.offset

func setMeshSize(size:Vector2) -> void:
	# 软缓存复用节点时尺寸通常不变，避免重复改写 QuadMesh 触发渲染服务器重建
	if _meshSizeInited and _gridSize == size:
		return
	_gridSize = size
	_meshSizeInited = true
	if multimesh and multimesh.mesh:
		(multimesh.mesh as QuadMesh).set_size(Vector2(size.x, -size.y))

# 公开方法用于控制颜色支持
func set_use_color(enabled:bool) -> void:
	if not multimesh:
		return
	if _drawMode != SwDefine.GridDrawMode.Tiling:
		# 内容层的实例数据块固定按含颜色的 16 floats 布局构建，不允许关闭颜色
		return
	multimesh.use_colors = enabled
	# 重置buffer以适应新的buffer大小
	buffer.clear()

# 获取当前颜色支持状态
func get_use_color() -> bool:
	return multimesh.use_colors if multimesh else false
	
func reUse() -> void:
	_hadDraw = false
	curMapData = []
	mapDataIns = null
	_slotStart.clear()
	_slotParts.clear()
	_slotsValid = false
	_usedInstances = 0
	_netCols.clear()
	_netMaskCols.clear()
	_netMaskColors.clear()

# 增量补丁要求常驻 CPU 缓冲与槽位表都在
func hasCpuBuffer() -> bool:
	return _slotsValid
	
var mapDataIns:SWBuildItemDefine = null
var bufferSize = 0

var curMapData:Array[SWBuildItemDefine]

# 同步绘制：函数返回时 buffer 已经提交给 MultiMesh，不再有"后台构建中"状态
func drawMap(mapData:Array[SWBuildItemDefine], _flashDrawRegion:bool = false) -> void:
	_gridSizeTmp = _gridSize * _swTransform.scale
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		if _hadDraw:
			return
		_hadDraw = true
	curMapData = mapData
	var buffer_size_per_instance = 12 if not multimesh.use_colors else 16
	bufferSize = n * buffer_size_per_instance
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		_buildTiling()
	elif _drawMode == SwDefine.GridDrawMode.ByContent:
		_buildContent()
	else:
		_buildSparse()

# 平铺层：单个地图资源铺满整块
func _buildTiling() -> void:
	if multimesh == null:
		return
	var use_colors: bool = multimesh.use_colors
	var stride: int = 16 if use_colors else 12
	if curMapData.is_empty():
		multimesh.visible_instance_count = 0
		return
	var need: int = n * stride
	if buffer.size() != need:
		buffer.resize(need)
	var ins: SWBuildItemDefine = curMapData[0]
	var grid_x: float = _gridSizeTmp.x
	var grid_y: float = _gridSizeTmp.y
	var rect: Rect2 = ins.getRenderableCompoent().drawRect
	var index: int = 0
	for i in range(e.x):
		for j in range(e.y):
			var t = Transform2D(
				deg_to_rad(ins.rotation*90),
				Vector2(grid_x * i + grid_x / 2.0, grid_y * j + grid_y / 2.0))
			_fill_instance(buffer, index*stride, t, _get_instance_color(ins, i, j), rect, use_colors)
			index += 1
	if multimesh.instance_count != index:
		multimesh.instance_count = index
	multimesh.set_buffer(buffer)
	multimesh.visible_instance_count = index
	multimesh.emit_changed()

# 内容层：逐建筑 append 预烘培好的整块数据（一次 memcpy），并记录实例槽位供增量回写
func _buildContent() -> void:
	if multimesh == null:
		return
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var cap: int = maxInstances
	var grid_x: float = _gridSizeTmp.x
	var grid_y: float = _gridSizeTmp.y
	var buf: PackedFloat32Array = _cpuBuffer
	buf.resize(0)
	_slotStart.clear()
	_slotParts.clear()
	_netCols.clear()
	_netMaskCols.clear()
	_netMaskColors.clear()
	var inst: int = 0
	for mapData:SWBuildItemDefine in curMapData:
		if inst >= cap:
			break
		var comp: SWBuildCompoentRenderable = mapData.getRenderableCompoent()
		var block: PackedFloat32Array = comp.getInstanceBlock(
				float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y), grid_x, grid_y,
				mapData.buildState.mask_color)
		if block.size() == 0:
			continue
		var parts: int = block.size() / stride
		var truncated: bool = false
		if inst + parts > cap:
			# 超出本区块实例上限时截断，只取放得下的部件
			parts = cap - inst
			if parts <= 0:
				break
			block = block.slice(0, parts * stride)
			truncated = true
		if not truncated:
			comp.registerNetColumns(inst, _netCols, _netMaskCols, _netMaskColors)
		_slotStart[mapData] = inst
		_slotParts[mapData] = parts
		buf.append_array(block)
		inst += parts
	_cpuBuffer = buf
	_usedInstances = inst
	_slotsValid = true
	_upload(inst)

# 手持/阴影图层：建筑数极少，逐实例写入即可
func _buildSparse() -> void:
	if multimesh == null:
		return
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var need: int = maxInstances * stride
	var buf: PackedFloat32Array = _cpuBuffer
	if buf.size() != need:
		buf.resize(need)
	var grid_x: float = _gridSizeTmp.x
	var grid_y: float = _gridSizeTmp.y
	var use_hold_alpha: bool = _drawMode == SwDefine.GridDrawMode.ByHold
	var inst: int = 0
	for mapData:SWBuildItemDefine in curMapData:
		if inst >= maxInstances:
			break
		var color: Color = mapData.buildState.mask_color
		if use_hold_alpha:
			color.a *= 0.85
		inst += mapData.getRenderableCompoent().writeInstances(
				buf, inst, float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y),
				grid_x, grid_y, color, maxInstances)
	_cpuBuffer = buf
	_slotStart.clear()
	_slotParts.clear()
	_slotsValid = false
	_usedInstances = inst
	_upload(inst)

# 信号变化只影响颜色与图集帧：按槽把每个实例的 8..15 列回写（不提交，交给 flushPatch）。
# 槽位缺失/部件数变化（几何变了）返回 false，由调用方退回整块重建。
func patchBuilds(builds:Array) -> bool:
	if not _slotsValid:
		return false
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	var grid_x: float = _gridSizeTmp.x
	var grid_y: float = _gridSizeTmp.y
	var buf: PackedFloat32Array = _cpuBuffer
	for mapData:SWBuildItemDefine in builds:
		if not _slotStart.has(mapData):
			return false
		var parts: int = _slotParts[mapData]
		var block: PackedFloat32Array = mapData.getRenderableCompoent().getInstanceBlock(
				float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y), grid_x, grid_y,
				mapData.buildState.mask_color)
		if block.size() != parts * stride:
			return false
		var dst: int = int(_slotStart[mapData]) * stride
		var src: int = 0
		for _p in parts:
			for k in range(8, stride):
				buf[dst + k] = block[src + k]
			dst += stride
			src += stride
	_cpuBuffer = buf
	return true

# 连线换色：只处理本区块内确实被翻转的 net，按预摊平的颜色列批量回写
func patchNets(netSet:Dictionary) -> bool:
	if (_netCols.is_empty() and _netMaskCols.is_empty()) or netSet.is_empty():
		return false
	var buf: PackedFloat32Array = _cpuBuffer
	var touched: bool = false
	for net:SWNet in _netCols.keys():
		dbg_net_checks += 1
		if not netSet.has(net):
			continue
		touched = true
		var c: Color = _net_color(net)
		var cols: PackedInt32Array = _netCols[net]
		dbg_cols_written += cols.size()
		for col: int in cols:
			buf[col + 0] = c.r
			buf[col + 1] = c.g
			buf[col + 2] = c.b
			buf[col + 3] = c.a
		_writeMaskCols(buf, net, c)
	#底色实例通常同时登记在白底索引里，这里只补「整块全是底色」的少数 net
	for net:SWNet in _netMaskCols.keys():
		if _netCols.has(net) or not netSet.has(net):
			continue
		touched = true
		_writeMaskCols(buf, net, _net_color(net))
	if touched:
		_cpuBuffer = buf
	return touched

func _writeMaskCols(buf: PackedFloat32Array, net: SWNet, c: Color) -> void:
	if not _netMaskCols.has(net):
		return
	var mcols: PackedInt32Array = _netMaskCols[net]
	var masks: PackedColorArray = _netMaskColors[net]
	for i in mcols.size():
		var col: int = mcols[i]
		var m: Color = masks[i]
		buf[col + 0] = c.r * m.r
		buf[col + 1] = c.g * m.g
		buf[col + 2] = c.b * m.b
		buf[col + 3] = c.a * m.a

# 补丁结束提交一次：同一帧里建筑补丁与连线换色共用一次上传
func flushPatch() -> void:
	if _slotsValid:
		_upload(_usedInstances)

# net 的电平色（低/高两档），与 _applyColors 里连线部件的取色规则一致
func _net_color(net:SWNet) -> Color:
	if not net.renderColorResolved:
		var wireName: String = net.wireGroup.wireName if net.wireGroup != null else ""
		var arr = SwCommon.GetWireColor(wireName)
		net.renderColorLow = arr[0]
		net.renderColorHigh = arr[1]
		net.renderColorResolved = true
	return net.renderColorHigh if net.curSignal == SwDefine.CircuitSignal.HIGH else net.renderColorLow

# 提交 _cpuBuffer 的前 inst 个实例；容量跟着真实用量走，避免上传大量补零实例
func _upload(inst: int) -> void:
	if multimesh == null:
		return
	if inst <= 0:
		multimesh.visible_instance_count = 0
		return
	var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
	if _cpuBuffer.size() != inst * stride:
		_cpuBuffer.resize(inst * stride)
	if multimesh.instance_count != inst:
		multimesh.instance_count = inst
	dbg_uploads += 1
	dbg_floats_uploaded += _cpuBuffer.size()
	multimesh.set_buffer(_cpuBuffer)
	multimesh.visible_instance_count = inst
	multimesh.emit_changed()

# 获取实例颜色的辅助函数
func _get_instance_color(mapData:SWBuildItemDefine, _grid_x:float, _grid_y:float) -> Color:
	var color = mapData.buildState.mask_color
	if _drawMode == SwDefine.GridDrawMode.ByHold:
		color.a *= 0.85
	return color

func _fill_instance(newBuffer:PackedFloat32Array, buffer_index:int, t:Transform2D, color:Color, rect:Rect2, use_colors:bool) -> void:
	newBuffer[buffer_index + 0] = t.x.x
	newBuffer[buffer_index + 1] = t.y.x
	newBuffer[buffer_index + 2] = 0
	newBuffer[buffer_index + 3] = t.origin.x
	newBuffer[buffer_index + 4] = t.x.y
	newBuffer[buffer_index + 5] = t.y.y
	newBuffer[buffer_index + 6] = 0
	newBuffer[buffer_index + 7] = t.origin.y
	if use_colors:
		newBuffer[buffer_index + 8] = color.r
		newBuffer[buffer_index + 9] = color.g
		newBuffer[buffer_index + 10] = color.b
		newBuffer[buffer_index + 11] = color.a
		newBuffer[buffer_index + 12] = float(rect.position.x)
		newBuffer[buffer_index + 13] = float(rect.position.y)
		newBuffer[buffer_index + 14] = float(rect.size.x)
		newBuffer[buffer_index + 15] = float(rect.size.y)
	else:
		newBuffer[buffer_index + 8] = float(rect.position.x)
		newBuffer[buffer_index + 9] = float(rect.position.y)
		newBuffer[buffer_index + 10] = float(rect.size.x)
		newBuffer[buffer_index + 11] = float(rect.size.y)
