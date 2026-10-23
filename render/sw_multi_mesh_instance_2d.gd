class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

var _swTransform:SwDefine.SWTransformData
var _gridSize:Vector2 = SwDefine.GRID_SIZE
# QuadMesh 尺寸是否已按 _gridSize 设置过（软缓存复用节点时尺寸不变则跳过）
var _meshSizeInited:bool = false
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
# 上次绘制时的建筑内容版本号：内容未变时可直接复用 MultiMesh 中已有的 buffer
var builtVersion:int = -1
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
# 该块缓冲是否已完成首次容量预留（内容层用整块 append 构造，只需清空长度）
var _pingPongReady: Array[bool] = [false, false]
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
	#(multimesh.mesh as QuadMesh).set_size(Vector2(_gridSize.x, -_gridSize.y)*_swTransform.scale)

func setMeshSize(size:Vector2) -> void:
	# 软缓存复用节点时尺寸通常不变，避免重复改写 QuadMesh 触发渲染服务器重建
	if _meshSizeInited and _gridSize == size:
		return
	_gridSize = size
	_meshSizeInited = true
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
	while planIsRunning:
		pass
	#buffer.clear()
	_hadDraw = false
	curMapData = []
	#bufferSize=0
	mapDataIns=null

# 区块进入软缓存时调用：释放 CPU 侧的双缓冲，仅保留 GPU 上的 MultiMesh buffer。
# 内容未变时重新上屏不需要重建，只有内容变化时才重新分配。
func releaseCpuBuffers() -> void:
	_pingPongBuffers[0].resize(0)
	_pingPongBuffers[1].resize(0)
	_pingPongReady[0] = false
	_pingPongReady[1] = false
	
var mapDataIns:SWBuildItemDefine = null
var bufferSize = 0

var curMapData:Array[SWBuildItemDefine]

func drawMap(mapData:Array[SWBuildItemDefine], _flashDrawRegion:bool = false) -> void:
	if _hadDraw:
		return
	_gridSizeTmp = _gridSize * _swTransform.scale
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		_hadDraw = true
	curMapData = mapData
	
	# 动态计算buffer大小
	var use_colors = multimesh.use_colors
	var buffer_size_per_instance = 12 if not use_colors else 16
	bufferSize = n * buffer_size_per_instance

	hasNewPlan = true
	semaphore.post()

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
		_pingPongIndex = 1 - _pingPongIndex
		var newBuffer = _pingPongBuffers[_pingPongIndex]
		var showCount = 0
		
		if _drawMode == SwDefine.GridDrawMode.Tiling:
			if newBuffer.size() != needed_size:
				newBuffer.resize(needed_size)
			if curMapData.is_empty():
				# 没有内容可画：必须复位构建标志，否则该区块永远被当成"仍在构建"，既不会被卸载也会长期占用并发名额
				planIsRunning = false
				continue
			var localMapDataIns:SWBuildItemDefine
			localMapDataIns = curMapData[0]
			for i in range(e.x):
				for j in range(e.y):
					var gridPos = Vector2i(_gridSizeTmp.x * i, _gridSizeTmp.y * j)
					var color = _get_instance_color(localMapDataIns, i, j)
					var t = Transform2D(
						deg_to_rad(localMapDataIns.rotation*90),
						Vector2(gridPos.x + _gridSizeTmp.x / 2.0, 
								gridPos.y + _gridSizeTmp.y / 2.0))
					var buffer_index = index * buffer_size_per_instance
					_fill_instance(newBuffer,buffer_index,t,color,localMapDataIns.getRenderableCompoent().drawRect,use_colors)
					index += 1
			showCount = e.x*e.y
		else:
			if curMapData.is_empty():
				showCount = 0
				# 空区块也要提交与容量一致的 buffer：MultiMesh.set_buffer 要求长度严格匹配
				if newBuffer.size() != needed_size:
					newBuffer.resize(needed_size)
				call_deferred("bufferCalFinish", newBuffer.duplicate(), showCount)
				planIsRunning = false
				continue
			var max_instances: int = maxInstances
			var grid_x: float = _gridSizeTmp.x
			var grid_y: float = _gridSizeTmp.y
			var use_hold_alpha: bool = _drawMode == SwDefine.GridDrawMode.ByHold
			var index_inst: int = 0
			if _drawMode == SwDefine.GridDrawMode.ByContent:
				# 内容层每帧要重绘大量建筑：直接 append 预烘培好的整块数据（一次 memcpy）
				if not _pingPongReady[_pingPongIndex]:
					newBuffer.resize(needed_size)
					_pingPongReady[_pingPongIndex] = true
				newBuffer.resize(0)
				var stride: int = SWBuildCompoentRenderable.INSTANCE_STRIDE
				for mapData:SWBuildItemDefine in curMapData:
					if index_inst >= max_instances:
						break
					var color: Color = mapData.buildState.mask_color
					var block: PackedFloat32Array = mapData.getRenderableCompoent().getInstanceBlock(
							float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y), grid_x, grid_y, color)
					var block_len: int = block.size()
					if block_len == 0:
						continue
					var block_parts: int = block_len / stride
					if index_inst + block_parts > max_instances:
						# 超出本区块实例上限时截断，只取放得下的部件
						var allowed: int = (max_instances - index_inst) * stride
						if allowed > 0:
							newBuffer.append_array(block.slice(0, allowed))
							index_inst = max_instances
						break
					newBuffer.append_array(block)
					index_inst += block_parts
				# MultiMesh.set_buffer 要求数组长度与实例总数一致，末尾补零到固定容量
				if newBuffer.size() != needed_size:
					newBuffer.resize(needed_size)
			else:
				# 手持/阴影图层的建筑数极少，逐实例写入即可，避免多图层线程争用烘培缓存
				if newBuffer.size() != needed_size:
					newBuffer.resize(needed_size)
				for mapData:SWBuildItemDefine in curMapData:
					if index_inst >= max_instances:
						break
					var color: Color = mapData.buildState.mask_color
					if use_hold_alpha:
						color.a *= 0.85
					index_inst += mapData.getRenderableCompoent().writeInstances(
							newBuffer, index_inst, float(mapData.buildAxisPos.x), float(mapData.buildAxisPos.y),
							grid_x, grid_y, color, max_instances)
			showCount = index_inst
		# 使用 call_deferred 传递数据，但 n 通过参数传递
		# 必须交独立快照：worker 紧接着就会复用同一块 ping-pong 缓冲，直接传引用会让
		# 主线程读到 worker 正在改写的数组（撕裂读），set_buffer 随即因长度不匹配而报错
		call_deferred("bufferCalFinish", newBuffer.duplicate(), showCount)
		planIsRunning = false

# 获取实例颜色的辅助函数
func _get_instance_color(mapData:SWBuildItemDefine, grid_x:float, grid_y:float) -> Color:
	var color = mapData.buildState.mask_color
	if _drawMode == SwDefine.GridDrawMode.ByHold:
		color.a *= 0.85
	return color

func bufferCalFinish(newBuffer:PackedFloat32Array, localN:int) -> void:
	if multimesh == null:
		return
	var stride:int = 16 if multimesh.use_colors else 12
	var need:int = multimesh.instance_count * stride
	if newBuffer.size() != need:
		# 兜底：长度不符时引擎会直接报错且不生效，这里补齐并把该区块隐藏，避免把残缺数据上屏
		newBuffer.resize(need)
		localN = 0
	multimesh.set_buffer(newBuffer)
	multimesh.visible_instance_count = localN
	multimesh.emit_changed()

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
