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
# 实例缓冲布局版本：custom_data 语义（style/net/palette/flags）变更时 +1。
# 软缓存复活路径按「内容版本 + 布局版本」双重比对，旧布局 buffer 绝不复用。
const BUFFER_LAYOUT_VERSION: int = 2
var e = Vector2i(SwDefine.CHUNK_SIZE, SwDefine.CHUNK_SIZE)
var n = e.x*e.y	
var maxInstances:int = 0   #含部件叠加后的最大实例容量
# 当前缩远简化档（0/1 = 满精度，>=2 = 只画主体部件）。
# 由 SWDrawManager 在视图变化时按相机缩放档位设置；切档会触发整块重建。
var content_lod:int = 0

# ========== 内容层持久缓冲 ==========
# 所有绘制都在主线程完成：没有工作线程，也就没有跨线程共享与 buffer 快照开销。
# _cpuBuffer 常驻，按实例排布（16 floats/实例）；_slotStart/_slotParts 记录每个建筑
# 占用的实例区间。信号翻转不再写 buffer（走信号纹理），只有内容变化（drawMap 整块重建）
# 与选中/环路底色（patchBuilds 只回写 8..11 tint 列）会碰它。
var _cpuBuffer: PackedFloat32Array = PackedFloat32Array()
var _slotStart: Dictionary = {}   # SWBuildItemDefine -> 起始实例下标
var _slotParts: Dictionary = {}   # SWBuildItemDefine -> 实例数
var _usedInstances: int = 0
var _slotsValid: bool = false
# 临时诊断计数（性能探针读取）
static var dbg_uploads: int = 0
static var dbg_floats_uploaded: int = 0
static var dbg_net_checks: int = 0
static var dbg_cols_written: int = 0

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
	# 运行前从全局配置 SwAtlas 取当前图集，覆盖 shader 采样用的 srcImg 与纹理 uniform
	# material 是场景子资源，被所有区块节点共享：参数已一致时必须跳过，
	# 否则每新增一个区块都会触发一次全量材质更新（区块越多越慢）
	# 登记进组：换图集/LOD 时由 SwAtlas 统一刷材质参数
	add_to_group(SwAtlas.MESH_GROUP)
	_resetShaderUniforms()

# 设置/刷新全部 shader uniform。池化复用（reUse）必须重新调用——池化节点不会再触发 _ready。
# 四个 sampler 一个都不能绑 null：GPU 后端会在 uniform_set_create 处直接报
# 「Texture is not a valid texture」并让整个材质失效（还不重试，一直黑到下一次成功刷新）。
# 这几张纹理都是惰性创建的，取不到时用全零兜底纹理顶上（shader 取到 rect=(0,0,0,0)）。
static var _fallback_tex: ImageTexture = null

static func _get_fallback_tex() -> ImageTexture:
	if _fallback_tex == null:
		var img := Image.create(1, 2, false, Image.FORMAT_RGBAF)
		_fallback_tex = ImageTexture.create_from_image(img)
	return _fallback_tex

func _resetShaderUniforms() -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	var tex: Texture2D = SwAtlas.get_texture()
	if tex == null:
		tex = _get_fallback_tex()
	if mat.get_shader_parameter("srcImg") != tex:
		mat.set_shader_parameter("srcImg", tex)
	var sc: float = SwAtlas.get_rect_scale()
	if mat.get_shader_parameter("atlas_scale") != sc:
		mat.set_shader_parameter("atlas_scale", sc)
	# 图集 rect 纹理 / 信号电平纹理 / 调色板纹理（惰性注册扩容后经 MESH_GROUP 回调统一刷新）
	var st: Texture2D = _get_fallback_tex()
	if SWStyleTexture.instance != null and SWStyleTexture.instance.texture != null:
		st = SWStyleTexture.instance.texture
	if mat.get_shader_parameter("styleTex") != st:
		mat.set_shader_parameter("styleTex", st)
	var stex: Texture2D = _get_fallback_tex()
	if SWSignalTexture.instance != null and SWSignalTexture.instance.texture != null:
		stex = SWSignalTexture.instance.texture
	if mat.get_shader_parameter("signalBits") != stex:
		mat.set_shader_parameter("signalBits", stex)
	var ptex: Texture2D = _get_fallback_tex()
	if SWSignalTexture.palette_texture != null:
		ptex = SWSignalTexture.palette_texture
	if mat.get_shader_parameter("paletteTex") != ptex:
		mat.set_shader_parameter("paletteTex", ptex)
	if mat.get_shader_parameter("signalCols") != SWSignalTexture.TEX_COLS:
		mat.set_shader_parameter("signalCols", SWSignalTexture.TEX_COLS)
	# LOD 冻结：连线统一 HIGH 色（等价旧 LOD 冻结语义，由 shader 采样侧处理）
	var frozen: float = 1.0 if SwAtlas.is_lod_active() else 0.0
	if mat.get_shader_parameter("signalFrozen") != frozen:
		mat.set_shader_parameter("signalFrozen", frozen)

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
	# 池化复用节点不会再触发 _ready：必须重设 shader uniform（纹理可能已扩容/换图集）
	_resetShaderUniforms()

# 增量补丁要求常驻 CPU 缓冲与槽位表都在
func hasCpuBuffer() -> bool:
	return _slotsValid

# 软缓存卸下时调用：只保留节点本身（MultiMeshInstance2D），释放 CPU 侧烘焙数据。
# 重新进视口时 drawMap 会重建 _cpuBuffer 与槽位表，builtVersion=-1 强制走整块重建。
# GPU 侧 visible_instance_count 清零，避免屏外 chunk 仍占绘制调用。
func freeCpuBuffer() -> void:
	_cpuBuffer.resize(0)
	_slotStart.clear()
	_slotParts.clear()
	_slotsValid = false
	_usedInstances = 0
	builtVersion = -1
	if multimesh:
		multimesh.visible_instance_count = 0
		
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
	# 地图层无信号：net_id=-1、palette=0、flags=0；style_id 惰性登记
	var styleId: int = SWStyleTexture.instance.register_rect(rect)
	var index: int = 0
	for i in range(e.x):
		for j in range(e.y):
			var t = Transform2D(
				deg_to_rad(ins.rotation*90),
				Vector2(grid_x * i + grid_x / 2.0, grid_y * j + grid_y / 2.0))
			_fill_instance(buffer, index*stride, t, _get_instance_color(ins, i, j), rect, use_colors,
					styleId, -1.0, 0.0, 0.0)
			index += 1
	if multimesh.instance_count != index:
		multimesh.instance_count = index
	multimesh.set_buffer(buffer)
	multimesh.visible_instance_count = index
	multimesh.emit_changed()

# 内容层：逐建筑 append 预烘培好的整块数据（一次 memcpy），并记录实例槽位供 tint 回写
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
	var inst: int = 0
	# 缩远简化档（见 SWBuildCompoentRenderable.getInstanceBlock 注释）：
	# 缩到 LOD 区之后每格只有几个像素，端子/底板是亚像素点，只画主体即可，
	# 实例数可降 2~5 倍。简化档下 _slotStart/_slotParts 不再可用（tint 回写会退回整块重建），
	# 但缩远时本来就几乎不选中建筑，可以接受。
	var lod: int = content_lod
	for mapData:SWBuildItemDefine in curMapData:
		if inst >= cap:
			break
		var comp: SWBuildCompoentRenderable = mapData.getRenderableCompoent()
		var block: PackedFloat32Array = comp.getInstanceBlock(
				float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y), grid_x, grid_y,
				mapData.buildState.mask_color, true, lod)
		if block.size() == 0:
			continue
		var parts: int = block.size() / stride
		if inst + parts > cap:
			# 超出本区块实例上限时截断，只取放得下的部件
			parts = cap - inst
			if parts <= 0:
				break
			block = block.slice(0, parts * stride)
		if lod < SWBuildCompoentRenderable.LOD_SIMPLIFY_LEVEL:
			_slotStart[mapData] = inst
			_slotParts[mapData] = parts
		buf.append_array(block)
		inst += parts
	_cpuBuffer = buf
	_usedInstances = inst
	# 简化档下槽位表为空，patchBuilds 走 _slotsValid=false 退回整块重建
	_slotsValid = lod < SWBuildCompoentRenderable.LOD_SIMPLIFY_LEVEL
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

# 信号变化不再写 buffer（走信号纹理）；本函数只回写 8..11 tint 列（选中底色/环路警示）。
# custom_data 12..15（style/net/palette/flags）是静态烘焙，永不在此改写。
# 槽位缺失/部件数变化（几何变了）返回 false，由调用方退回整块重建。
# forceColor/colorOnly 参数保留兼容旧调用（LOD 冻结改由 shader signalFrozen 处理）。
func patchBuilds(builds:Array, forceColor:bool = false, colorOnly:bool = false) -> bool:
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
				mapData.buildState.mask_color, true)
		if block.size() != parts * stride:
			return false
		var dst: int = int(_slotStart[mapData]) * stride
		var src: int = 0
		for _p in parts:
			for k in range(8, 12):
				buf[dst + k] = block[src + k]
			dst += stride
			src += stride
	_cpuBuffer = buf
	return true

# 补丁结束提交一次（内容/选中路径使用；tick 高频路径不再经过这里）
func flushPatch() -> void:
	if _slotsValid:
		_upload(_usedInstances)

# LOD 档切换：颜色已全部由 shader 采样（tint 静态 + 信号纹理 + signalFrozen），
# 无需重染 buffer。保留接口兼容旧调用，直接返回 true。
func resyncColors(_forceColor:bool = false) -> bool:
	return true

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

# Tiling 层专用：直接把单实例写入扁平 buffer。
# 布局：[0..7]=transform [8..11]=tint [12..15]=[style_id, net_id, palette_id, flags]
func _fill_instance(newBuffer:PackedFloat32Array, buffer_index:int, t:Transform2D, color:Color, rect:Rect2, use_colors:bool,
		style_id:float, net_id:float, palette_id:float, flags:float) -> void:
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
		newBuffer[buffer_index + 12] = style_id
		newBuffer[buffer_index + 13] = net_id
		newBuffer[buffer_index + 14] = palette_id
		newBuffer[buffer_index + 15] = flags
	else:
		newBuffer[buffer_index + 8] = style_id
		newBuffer[buffer_index + 9] = net_id
		newBuffer[buffer_index + 10] = palette_id
		newBuffer[buffer_index + 11] = flags
