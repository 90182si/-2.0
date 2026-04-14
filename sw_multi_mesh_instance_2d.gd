class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

var _swTransform:SWDefine.SWTransformData
var _gridSize:Vector2 = SWDefine.GRID_SIZE
var _drawMode:SWDefine.GridDrawMode=SWDefine.GridDrawMode.Tiling

var chunkPtr:SWDefine.SWDrawChunkData = null
var thread:Thread = null
var buffer:PackedFloat32Array

# ========== 线程安全变量 ==========
var _stopThread:int = 0           # 受 mutex 保护
var _alive:bool = true            # 受 mutex 保护
var _hadDraw:bool = false         # 受 mutex 保护
var _gridSizeTmp:Vector2 = Vector2.ZERO  # 受 mutex 保护
var _visibleCount:int = 0         # 受 mutex 保护，用于 bufferCalFinish

var hasNewPlan = false
var e = Vector2i(SWDefine.CHUNK_SIZE, SWDefine.CHUNK_SIZE)
var n = e.x*e.y	
var planIsRunning = false
#var mutex:Mutex
var semaphore: Semaphore
var semaphore2: Semaphore

func setDrawMode(mode:SWDefine.GridDrawMode) -> void:
	_drawMode = mode
	if _drawMode == SWDefine.GridDrawMode.Tiling:
		z_index = -100
	elif _drawMode == SWDefine.GridDrawMode.ByContent:
		z_index = 0
	elif _drawMode == SWDefine.GridDrawMode.HoldShadow:
		z_index = 50
	elif _drawMode == SWDefine.GridDrawMode.ByHold:
		z_index = 100
		
func resetOffsetAndScale(_swTf:SWDefine.SWTransformData) -> void:
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

func _init() -> void:
	_swTransform = SWDefine.SWTransformData.new()
	thread = Thread.new()
	semaphore = Semaphore.new()
	semaphore2 = Semaphore.new()
	#mutex = Mutex.new()
	n = e.x * e.y
	if multimesh:
		# 启用颜色支持（如果需要）
		multimesh.use_colors = true
		multimesh.instance_count = n
	thread.start(calBuffer)

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
	
var mapDataIns:SWDefine.SWBuildItemDefine = null
var bufferSize = 0

var curMapData:Array[SWDefine.SWBuildItemDefine]

func drawMap(mapData:Array[SWDefine.SWBuildItemDefine], _flashDrawRegion:bool = false) -> void:
	if _hadDraw:
		return
	_gridSizeTmp = _gridSize * _swTransform.scale
	if _drawMode == SWDefine.GridDrawMode.Tiling:
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
		var newBuffer:PackedFloat32Array
		# 根据是否使用颜色调整buffer大小
		var use_colors = multimesh.use_colors
		var buffer_size_per_instance = 12 if not use_colors else 16
		newBuffer.resize(n * buffer_size_per_instance)
		var showCount = 0
		
		if _drawMode == SWDefine.GridDrawMode.Tiling:
			if curMapData.is_empty():
				continue
			var localMapDataIns:SWDefine.SWBuildItemDefine
			localMapDataIns = curMapData[0]
			for i in range(e.x):
				for j in range(e.y):
					var gridPos = Vector2i(_gridSizeTmp.x * i, _gridSizeTmp.y * j)
					var t = Transform2D(
						deg_to_rad(localMapDataIns.rotation),
						Vector2(gridPos.x + _gridSizeTmp.x / 2.0, 
								gridPos.y + _gridSizeTmp.y / 2.0))
					
					var buffer_index = index * buffer_size_per_instance
					
					# Transform2D (8个float)
					newBuffer[buffer_index + 0] = t.x.x
					newBuffer[buffer_index + 1] = t.x.y
					newBuffer[buffer_index + 2] = 0
					newBuffer[buffer_index + 3] = t.origin.x
					newBuffer[buffer_index + 4] = t.x.y
					newBuffer[buffer_index + 5] = t.y.y
					newBuffer[buffer_index + 6] = 0
					newBuffer[buffer_index + 7] = t.origin.y
					
					# 颜色数据 (4个float) - 如果开启use_color，放到UV数据之前
					if use_colors:
						var color = _get_instance_color(localMapDataIns, i, j)
						newBuffer[buffer_index + 8] = color.r
						newBuffer[buffer_index + 9] = color.g
						newBuffer[buffer_index + 10] = color.b
						newBuffer[buffer_index + 11] = color.a
						
						# UV数据 (4个float) - 必须放在最后，INSTANCE_CUSTOM才能正确读取
						newBuffer[buffer_index + 12] = float(localMapDataIns.buildDefine.atlasTexture.region.position.x)
						newBuffer[buffer_index + 13] = float(localMapDataIns.buildDefine.atlasTexture.region.position.y)
						newBuffer[buffer_index + 14] = float(localMapDataIns.buildDefine.atlasTexture.region.size.x)
						newBuffer[buffer_index + 15] = float(localMapDataIns.buildDefine.atlasTexture.region.size.y)
					else:
						# 如果不使用颜色，UV数据仍然需要放在最后4个位置
						newBuffer[buffer_index + 8] = float(localMapDataIns.buildDefine.atlasTexture.region.position.x)
						newBuffer[buffer_index + 9] = float(localMapDataIns.buildDefine.atlasTexture.region.position.y)
						newBuffer[buffer_index + 10] = float(localMapDataIns.buildDefine.atlasTexture.region.size.x)
						newBuffer[buffer_index + 11] = float(localMapDataIns.buildDefine.atlasTexture.region.size.y)
					
					index += 1
			showCount = e.x*e.y
		else:
			for mapData in curMapData:
				var gridPos = mapData.buildAxisPos
				var t = Transform2D(
					deg_to_rad(mapData.rotation),
					Vector2(gridPos.x + _gridSizeTmp.x / 2.0, 
							gridPos.y + _gridSizeTmp.y / 2.0))
				
				var buffer_index = index * buffer_size_per_instance
				
				# Transform2D (8个float)
				newBuffer[buffer_index + 0] = t.x.x
				newBuffer[buffer_index + 1] = t.x.y
				newBuffer[buffer_index + 2] = 0
				newBuffer[buffer_index + 3] = t.origin.x
				newBuffer[buffer_index + 4] = t.x.y
				newBuffer[buffer_index + 5] = t.y.y
				newBuffer[buffer_index + 6] = 0
				newBuffer[buffer_index + 7] = t.origin.y
				
				# 颜色数据 (4个float) - 如果开启use_color，放到UV数据之前
				if use_colors:
					var color = _get_instance_color(mapData, gridPos.x / _gridSizeTmp.x, gridPos.y / _gridSizeTmp.y)
					newBuffer[buffer_index + 8] = color.r
					newBuffer[buffer_index + 9] = color.g
					newBuffer[buffer_index + 10] = color.b
					newBuffer[buffer_index + 11] = color.a
					
					# UV数据 (4个float) - 必须放在最后，INSTANCE_CUSTOM才能正确读取
					newBuffer[buffer_index + 12] = float(mapData.buildDefine.atlasTexture.region.position.x)
					newBuffer[buffer_index + 13] = float(mapData.buildDefine.atlasTexture.region.position.y)
					newBuffer[buffer_index + 14] = float(mapData.buildDefine.atlasTexture.region.size.x)
					newBuffer[buffer_index + 15] = float(mapData.buildDefine.atlasTexture.region.size.y)
				else:
					# 如果不使用颜色，UV数据仍然需要放在最后4个位置
					newBuffer[buffer_index + 8] = float(mapData.buildDefine.atlasTexture.region.position.x)
					newBuffer[buffer_index + 9] = float(mapData.buildDefine.atlasTexture.region.position.y)
					newBuffer[buffer_index + 10] = float(mapData.buildDefine.atlasTexture.region.size.x)
					newBuffer[buffer_index + 11] = float(mapData.buildDefine.atlasTexture.region.size.y)
				
				index += 1
			showCount = curMapData.size()
		# 使用 call_deferred 传递数据，但 n 通过参数传递
		call_deferred("bufferCalFinish", newBuffer, showCount)
		planIsRunning = false

# 获取实例颜色的辅助函数
func _get_instance_color(mapData:SWDefine.SWBuildItemDefine, grid_x:float, grid_y:float) -> Color:
	# 默认颜色方案 - 可以根据需要修改
	var default_color = Color.WHITE
	
	return mapData.innerData.mask_color
	## 根据建筑状态（IDLE/SELECTED）返回颜色
	#if mapData.innerData and mapData.innerData.has("state"):
		#match mapData.innerData.state:
			#SWDefine.BuildState.SELECTED:
				#return Color.YELLOW  # 选中状态为黄色
			#SWDefine.BuildState.IDLE:
				#return Color.WHITE    # 默认状态为白色
	#
	## 根据建筑类型返回颜色（示例）
	#var build_name = ""
	#if mapData.buildDefine and mapData.buildDefine.has("buildName"):
		#build_name = mapData.buildDefine.buildName
	#
	#match build_name:
		#"按钮":
			#return Color(1.0, 0.8, 0.2)  # 金色
		#"开关":
			#return Color(0.2, 0.8, 1.0)  # 蓝色
		#"灯泡":
			#return Color(1.0, 1.0, 0.2)  # 黄色
		#_:
			## 根据位置生成渐变颜色（可选）
			#var noise_color = Color(
				#0.8 + 0.2 * sin(grid_x * 0.1),
				#0.8 + 0.2 * sin(grid_y * 0.1),
				#0.8 + 0.2 * sin((grid_x + grid_y) * 0.05),
				#1.0
			#)
			#return noise_color

func bufferCalFinish(newBuffer:PackedFloat32Array, localN:int) -> void:
	multimesh.set_buffer(newBuffer)
	multimesh.visible_instance_count = localN
	multimesh.emit_changed()
