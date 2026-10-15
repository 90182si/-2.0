class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

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
	# 运行前从全局配置 SwAtlas 取当前图集，覆盖 shader 采样用的 srcImg
	var mat := material as ShaderMaterial
	if mat and SwAtlas.current:
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
	while planIsRunning:
		pass
	#buffer.clear()
	_hadDraw = false
	curMapData = []
	#bufferSize=0
	mapDataIns=null
	
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
	
	if buffer.size() == 0:
		buffer = multimesh.get_buffer()
		# 如果当前buffer大小不匹配，重新分配
		if buffer.size() != bufferSize:
			buffer.resize(bufferSize)
	
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
		if _pingPongBuffers[_pingPongIndex].size() != needed_size:
			_pingPongBuffers[_pingPongIndex].resize(needed_size)
		var newBuffer = _pingPongBuffers[_pingPongIndex]
		var showCount = 0
		
		if _drawMode == SwDefine.GridDrawMode.Tiling:
			if curMapData.is_empty():
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
				call_deferred("bufferCalFinish", newBuffer, showCount)
				planIsRunning = false
				continue
			var max_instances = maxInstances
			for mapData:SWBuildItemDefine in curMapData:
				if index >= max_instances:
					break
				var gridPos = mapData.buildAxisPos
				var color = _get_instance_color(mapData, gridPos.x / _gridSizeTmp.x, gridPos.y / _gridSizeTmp.y)
				var render_able = mapData.getCompoent(SwDefine.BuildCompoentType.RENDER_ABLE) as SWBuildCompoentRenderable
				var parts = render_able.getRenderParts()
				for part in parts:
					if index >= max_instances:
						break
					var offset:Vector2i = part["offset"]
					var t = Transform2D(
						deg_to_rad(part["rotation"]*90),
						Vector2(gridPos.x + _gridSizeTmp.x * (offset.x + 0.5), 
								gridPos.y + _gridSizeTmp.y * (offset.y + 0.5)))
					var buffer_index = index * buffer_size_per_instance
					var use_color = part["use_color"]
					if use_color:
						var mix_color = color * part["color"]
						_fill_instance(newBuffer,buffer_index,t,mix_color,part["rect"],use_colors)
					else:
						_fill_instance(newBuffer,buffer_index,t,color,part["rect"],use_colors)
					index += 1
			showCount = index
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
