class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

# ========== 性能计数器（static，不持久化） ==========
static var s_draw_map_call_count: int = 0
# R3.1：补丁命中次数与整块重填次数，用于确认增量路径真的生效
static var s_patch_hit_count: int = 0
static var s_full_refill_count: int = 0
# 补丁退回整块重填的原因计数（reason -> 次数）
static var s_patch_bail: Dictionary = {}
# R3.3：命中「只覆写主体 style 浮点」快速通道的建筑数
static var s_patch_style_only_count: int = 0

var _swTransform:SwDefine.SWTransformData
var _gridSize:Vector2 = SwDefine.GRID_SIZE
var _drawMode:SwDefine.GridDrawMode=SwDefine.GridDrawMode.Tiling

var thread:Thread = null
var buffer:PackedFloat32Array

# ========== 线程安全变量 ==========
var _stopThread:int = 0           # 受 mutex 保护
var _alive:bool = true            # 受 mutex 保护
var _hadDraw:bool = false         # 受 mutex 保护
var _gridSizeTmp:Vector2 = Vector2.ZERO  # 受 mutex 保护
var _visibleCount:int = 0         # 受 mutex 保护，用于 bufferCalFinish

var hasNewPlan = false
var e = Vector2i(SwDefine.CHUNK_SIZE, SwDefine.CHUNK_SIZE)
var n = e.x*e.y	
var maxInstances:int = 0   #含部件叠加后的最大实例容量
var planIsRunning = false
#var mutex:Mutex
var semaphore: Semaphore
var semaphore2: Semaphore

# ========== 双缓冲(ping-pong) ==========
# 交替使用两块预分配缓冲区，避免每次绘制都重新分配并清零大数组
var _pingPongBuffers: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
var _pingPongIndex: int = 0
func _init() -> void:
	_swTransform = SwDefine.SWTransformData.new()
	semaphore = Semaphore.new()
	semaphore2 = Semaphore.new()
	#mutex = Mutex.new()
	n = e.x * e.y
	maxInstances = n * SwDefine.MAX_RENDER_PARTS
	if multimesh:
		# 启用颜色支持（如果需要）
		multimesh.use_colors = true
		multimesh.instance_count = maxInstances
	#线程改由 _enter_tree 启动、_exit_tree 停止，确保只在节点位于场景树时存活

func _enter_tree() -> void:
	_alive = true
	if thread == null:
		thread = Thread.new()
	if not thread.is_started():
		thread.start(calBuffer)
	
func _ready() -> void:
	_resetShaderUniforms()

# 抽取 uniform 设置逻辑，供 _ready() 和 reUse() 共用
func _resetShaderUniforms() -> void:
	var mat := material as ShaderMaterial
	if not mat:
		return
	if SwAtlas.current:
		mat.set_shader_parameter("srcImg", SwAtlas.current)
	else:
		push_warning("SWMultiMeshInstance2D: SwAtlas.current is null, srcImg not set")
	if SWStyleTexture.instance:
		mat.set_shader_parameter("styleTex", SWStyleTexture.instance.texture)
	else:
		push_warning("SWMultiMeshInstance2D: SWStyleTexture.instance is null, styleTex not set")
	if SWSignalTexture.instance:
		mat.set_shader_parameter("signalTex", SWSignalTexture.instance.texture)
		mat.set_shader_parameter("signalCols", SWSignalTexture.TEX_COLS)
	else:
		push_warning("SWMultiMeshInstance2D: SWSignalTexture.instance is null, signalTex not set")
		
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
	#(multimesh.mesh as QuadMesh).set_size(Vector2(_gridSize.x, -_gridSize.y)*_swTransform.scale)

func setMeshSize(size:Vector2) -> void:
	_gridSize = size
	if multimesh and multimesh.mesh:
		(multimesh.mesh as QuadMesh).set_size(Vector2(size.x, -size.y))
	
func _exit_tree() -> void:
	_alive = false
	semaphore.post()
	if thread and thread.is_started():
		thread.wait_to_finish()
	thread = null

# 公开方法用于控制颜色支持
func set_use_color(enabled:bool) -> void:
	if multimesh:
		multimesh.use_colors = enabled
		# 重置buffer以适应新的buffer大小
		buffer.clear()

# 获取当前颜色支持状态
func get_use_color() -> bool:
	return multimesh.use_colors if multimesh else false
	
func reUse() -> void:
	if planIsRunning:
		push_warning("reUse() called while calBuffer still running, forcing wait...")
		# 线程在 _exit_tree 时会 join，正常流程此处应为 false
		# 防御性等待：最多等几帧让 deferred 调用完成
		var wait_frames := 0
		while planIsRunning and wait_frames < 10:
			await get_tree().process_frame
			wait_frames += 1
		if planIsRunning:
			push_error("reUse(): planIsRunning still true after 10 frames, force reset")
			planIsRunning = false
	# 池化复用：重新设置 shader uniform（_ready 不会再次触发）
	_resetShaderUniforms()
	_hadDraw = false
	curMapData = []
	# R3.1：实例池复用后建筑与实例号的对应关系作废，下一次必须整块重填
	_instRanges.clear()
	_pendingPatchBuilds = []
	_lastShowCount = 0
	_rangesBufferIndex = -1
	mapDataIns=null
	
var mapDataIns:SWBuildItemDefine = null
var bufferSize = 0

var curMapData:Array[SWBuildItemDefine]

# ========== R3.1 按建筑增量补丁 ==========
# 整块填充时记录 build -> [起始实例号, 部件数]。信号变化只需要改这几个建筑的实例行，
# 不必把块内所有建筑重发一遍（16 个计数器时整块重填是最大耗时项）。
# 任一补丁建筑没有区间记录、或部件数发生变化，都退回整块重填。
var _instRanges: Dictionary = {}
# 由主线程在 drawMap 里写入、工作线程消费（与 curMapData 同一套 semaphore 握手约定）。
# 元素是 [建筑, parts 快照, style 补丁]，两者互斥：
# - parts 快照非空：结构变了，工作线程整行重写该建筑的实例
# - style 补丁非空：只换了主体贴图，元素是 [style_id, bodyStart, bodyCount]，只覆写那几行的 style 浮点
var _pendingPatchBuilds: Array = []
var _lastShowCount: int = 0
# 记录区间时所处的双缓冲代次；代次变了说明区间对应的已不是当前缓冲内容，补丁失效
var _rangesBufferIndex: int = -1

func drawMap(mapData:Array[SWBuildItemDefine], _flashDrawRegion:bool = false, patchBuilds:Array = []) -> void:
	SWMultiMeshInstance2D.s_draw_map_call_count += 1
	if _hadDraw:
		return
	# _gridSizeTmp 是 var，工作线程会读它：必须在 semaphore.post() 之前、且只有整块重绘才刷新，
	# 否则补丁帧的赋值会与 calBuffer 的读取竞争，导致实例坐标用错缩放
	if patchBuilds.is_empty():
		_gridSizeTmp = _gridSize * _swTransform.scale
		# 整块重填请求会替换 buffer 内容：在真正执行前，旧的实例区间一律视为失效。
		# 若本次请求与后续补丁请求被工作线程合并（semaphore 计数 >1 时数据以后者为准），
		# 补丁分支会因代次不符退回整块重填，不会把补丁写到从未填充过的 buffer 上。
		_rangesBufferIndex = -1
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		_hadDraw = true
	curMapData = mapData
	_pendingPatchBuilds = patchBuilds
	hasNewPlan = true
	semaphore.post()

## 补丁可行性校验：每个补丁建筑都要有区间记录；结构补丁的部件数不变，
## style 补丁的主体区间必须落在登记的实例行内。
## 退回整块重填时把原因计入 s_patch_bail（reason -> 次数），验收时可直接定位是哪条守卫失效。
func _can_patch() -> bool:
	if _drawMode != SwDefine.GridDrawMode.ByContent:
		return _patch_bail("not_by_content")
	if _pendingPatchBuilds.is_empty():
		return _patch_bail("no_patch_builds")
	if _instRanges.is_empty():
		return _patch_bail("no_ranges")
	if _lastShowCount <= 0:
		return _patch_bail("empty_last_fill")
	if _pingPongIndex != _rangesBufferIndex:
		return _patch_bail("buffer_generation_changed")
	var max_instances = maxInstances
	for entry: Array in _pendingPatchBuilds:
		var rng: Array = _instRanges.get(entry[0], [])
		if rng.is_empty():
			return _patch_bail("build_has_no_range")
		if int(rng[0]) + int(rng[1]) > max_instances:
			return _patch_bail("instance_capacity_overflow")
		var style_patch: Array = entry[2]
		if style_patch.is_empty():
			# R3.3：部件快照由主线程随补丁一起下发，这里只比大小，不再回调 getRenderParts
			if (entry[1] as Array).size() != int(rng[1]):
				return _patch_bail("part_count_changed")
		elif int(style_patch[1]) + int(style_patch[2]) > int(rng[1]):
			# 主体区间必须落在该建筑登记的实例行内（快照与区间登记不同步则退回整块重填）
			return _patch_bail("style_patch_out_of_range")
	return true

func _patch_bail(reason: String) -> bool:
	SWMultiMeshInstance2D.s_patch_bail[reason] = int(SWMultiMeshInstance2D.s_patch_bail.get(reason, 0)) + 1
	return false

## 把一个建筑的部件写入缓冲；返回下一个可用实例号，实例容量不足时返回 -1
func _write_parts(newBuffer: PackedFloat32Array, index: int, mapData: SWBuildItemDefine, parts: Array, bspd: int, use_colors: bool, max_instances: int) -> int:
	var gridPos = mapData.buildAxisPos
	# ByContent 模式下 _get_instance_color 的 ByHold 分支恒不成立，直接取 mask_color
	var color: Color = mapData.buildState.mask_color
	for part in parts:
		if index >= max_instances:
			return -1
		var offset:Vector2i = part["offset"]
		var t = Transform2D(
			deg_to_rad(part["rotation"]*90),
			Vector2(gridPos.x + _gridSizeTmp.x * (offset.x + 0.5),
					gridPos.y + _gridSizeTmp.y * (offset.y + 0.5)))
		var buffer_index = index * bspd
		if part["use_color"]:
			_fill_instance(newBuffer,buffer_index,t,color * part["color"],part["style_id"],part["net_id"],part["flags"],use_colors)
		else:
			_fill_instance(newBuffer,buffer_index,t,color,part["style_id"],part["net_id"],part["flags"],use_colors)
		index += 1
	return index

func calBuffer() -> void:
	while true:
		if not _alive:
			break
		semaphore.wait()
		planIsRunning = true
		var index = 0
		# 根据是否使用颜色调整buffer大小
		var use_colors = multimesh.use_colors
		var buffer_size_per_instance = 12 if not use_colors else 16
		var needed_size = maxInstances * buffer_size_per_instance
		# 双缓冲交替：仅当容量或每实例字节数变化时才 resize，正常绘制直接复用，避免每帧分配与清零
		#_pingPongIndex = 1 - _pingPongIndex
		if _pingPongBuffers[_pingPongIndex].size() != needed_size:
			_pingPongBuffers[_pingPongIndex].resize(needed_size)
		var newBuffer = _pingPongBuffers[_pingPongIndex]
		var showCount = 0
		
		if _drawMode == SwDefine.GridDrawMode.Tiling:
			if curMapData.is_empty():
				continue
			var localMapDataIns:SWBuildItemDefine
			localMapDataIns = curMapData[0]
			var tiling_draw_rect: Rect2 = localMapDataIns.getRenderableCompoent().drawRect
			var tiling_style_id: int = SWStyleTexture.instance.get_style_id(tiling_draw_rect) if SWStyleTexture.instance else -1
			for i in range(e.x):
				for j in range(e.y):
					var gridPos = Vector2i(_gridSizeTmp.x * i, _gridSizeTmp.y * j)
					var color = _get_instance_color(localMapDataIns, i, j)
					var t = Transform2D(
						deg_to_rad(localMapDataIns.rotation*90),
						Vector2(gridPos.x + _gridSizeTmp.x / 2.0, 
								gridPos.y + _gridSizeTmp.y / 2.0))
					var buffer_index = index * buffer_size_per_instance
					_fill_instance(newBuffer,buffer_index,t,color,tiling_style_id,-1,0,use_colors)
					index += 1
			showCount = e.x*e.y
		else:
			if curMapData.is_empty():
				showCount = 0
				_pendingPatchBuilds = []
				call_deferred("bufferCalFinish", newBuffer, showCount)
				planIsRunning = false
				continue
			var max_instances = maxInstances
			# R3.1：信号变化帧只覆写变化建筑的实例行，其余保持上一次整块填充的结果
			if _can_patch():
				SWMultiMeshInstance2D.s_patch_hit_count += 1
				# style 浮点位置：use_colors 时 custom0 在第 12 个 float，否则第 8 个
				var style_slot: int = 12 if use_colors else 8
				for entry: Array in _pendingPatchBuilds:
					var pb: SWBuildItemDefine = entry[0]
					var rng: Array = _instRanges[pb]
					var start_index: int = int(rng[0])
					var style_patch: Array = entry[2]
					# R3.4 快速通道：本拍只换了主体贴图，主线程只下发 [style_id, bodyStart, bodyCount]，
					# 这里只覆写主体那几行的 style 浮点。_can_patch 已确认区间代次与当前缓冲一致，
					# 而这些行自上次整块重填以来只被本线程写过，其余字节无需重算。
					if not style_patch.is_empty():
						SWMultiMeshInstance2D.s_patch_style_only_count += 1
						var style_val: float = float(style_patch[0])
						var upto: int = mini(int(style_patch[1]) + int(style_patch[2]), int(rng[1]))
						for k in range(int(style_patch[1]), upto):
							newBuffer[(start_index + k) * buffer_size_per_instance + style_slot] = style_val
					else:
						_write_parts(newBuffer, start_index, pb, entry[1], buffer_size_per_instance, use_colors, max_instances)
				showCount = _lastShowCount
			else:
				SWMultiMeshInstance2D.s_full_refill_count += 1
				_instRanges.clear()
				for mapData:SWBuildItemDefine in curMapData:
					var render_able: SWBuildCompoentRenderable = mapData.getRenderableCompoent()
					var parts = render_able.getRenderParts()
					SWBuildCompoentRenderable.s_get_render_parts_call_count += 1
					var start_index: int = index
					var next := _write_parts(newBuffer, index, mapData, parts, buffer_size_per_instance, use_colors, max_instances)
					if next < 0:
						# 实例容量溢出：本建筑及其后都不登记区间，补丁路径自动失效退回整块重填
						break
					_instRanges[mapData] = [start_index, parts.size()]
					index = next
				showCount = index
				_lastShowCount = showCount
				_rangesBufferIndex = _pingPongIndex
			_pendingPatchBuilds = []
		# 使用 call_deferred 传递数据，但 n 通过参数传递
		call_deferred("bufferCalFinish", newBuffer, showCount)
		planIsRunning = false

# 获取实例颜色的辅助函数
func _get_instance_color(mapData:SWBuildItemDefine, grid_x:float, grid_y:float) -> Color:
	var color = mapData.buildState.mask_color
	if _drawMode == SwDefine.GridDrawMode.ByHold:
		color.a *= 0.85
	return color

func bufferCalFinish(newBuffer:PackedFloat32Array, localN:int) -> void:
	multimesh.set_buffer(newBuffer)
	multimesh.visible_instance_count = localN
	multimesh.emit_changed()

func _fill_instance(newBuffer:PackedFloat32Array, buffer_index:int, t:Transform2D, color:Color, style_id:int, net_id:int, flags:int, use_colors:bool) -> void:
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
		newBuffer[buffer_index + 12] = float(style_id)
		newBuffer[buffer_index + 13] = float(net_id)
		newBuffer[buffer_index + 14] = float(flags)
		newBuffer[buffer_index + 15] = 0.0
	else:
		newBuffer[buffer_index + 8] = float(style_id)
		newBuffer[buffer_index + 9] = float(net_id)
		newBuffer[buffer_index + 10] = float(flags)
		newBuffer[buffer_index + 11] = 0.0
