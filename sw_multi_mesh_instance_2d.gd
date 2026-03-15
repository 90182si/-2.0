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
var mutex:Mutex
var semaphore: Semaphore

func setDrawMode(mode:SWDefine.GridDrawMode) -> void:
	mutex.lock()
	_drawMode = mode
	mutex.unlock()
	
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
	
	(multimesh.mesh as QuadMesh).set_size(Vector2(_gridSize.x, -_gridSize.y)*_swTransform.scale)

func setMeshSize(size:Vector2) -> void:
	_gridSize = size
	if multimesh and multimesh.mesh:
		(multimesh.mesh as QuadMesh).set_size(Vector2(size.x, -size.y))
	
func _exit_tree() -> void:
	mutex.lock()
	_alive = false
	mutex.unlock()
	semaphore.post()
	if thread and thread.is_started():
		thread.wait_to_finish()

func _init() -> void:
	_swTransform = SWDefine.SWTransformData.new()
	thread = Thread.new()
	semaphore = Semaphore.new()
	mutex = Mutex.new()
	
	# 初始化 n
	n = e.x * e.y
	
	if multimesh:
		multimesh.instance_count = n
	
	thread.start(calBuffer)
	
var mapDataIns:SWDefine.SWBuildItemDefine = null
var bufferSize = 0

var curMapData:Array[SWDefine.SWBuildItemDefine]

func drawMap(mapData:Array[SWDefine.SWBuildItemDefine], _flashDrawRegion:bool = false) -> void:
	# 线程安全地更新 gridSizeTmp
	mutex.lock()
	_gridSizeTmp = _gridSize * _swTransform.scale
	
	# 线程安全地更新 hadDraw
	if _drawMode == SWDefine.GridDrawMode.Tiling:
		_hadDraw = true
	mutex.unlock()
	
	# 线程安全地复制 curMapData
	mutex.lock()
	curMapData = mapData.duplicate(true)  # 深拷贝避免引用问题
	mutex.unlock()
	
	mutex.lock()
	if buffer.size() == 0:
		buffer = multimesh.get_buffer()
		bufferSize = buffer.size()
	mutex.unlock()
	
	hasNewPlan = true
	semaphore.post()

func calBuffer() -> void:
	while true:
		# 线程安全地检查 alive
		mutex.lock()
		var isAlive = _alive
		mutex.unlock()
		
		if not isAlive:
			break
			
		semaphore.wait()
		
		mutex.lock()
		isAlive = _alive
		if not isAlive:
			mutex.unlock()
			continue
		mutex.unlock()
		
		var index = 0
		var newBuffer:PackedFloat32Array
		newBuffer.resize(bufferSize)
		
		# 线程安全地获取 drawMode
		mutex.lock()
		var currentDrawMode = _drawMode
		mutex.unlock()
		
		if currentDrawMode == SWDefine.GridDrawMode.Tiling:
			mutex.lock()
			var localMapDataIns:SWDefine.SWBuildItemDefine
			if curMapData.is_empty():
				mutex.unlock()
				continue
			localMapDataIns = curMapData[0]
			
			# 线程安全地获取 gridSizeTmp
			var localGridSizeTmp = _gridSizeTmp
			mutex.unlock()
			
			mutex.lock()
			var localHadDraw = _hadDraw
			mutex.unlock()
			
			for i in range(e.x):
				mutex.lock()
				var stillAlive = _alive
				mutex.unlock()
				if not stillAlive:
					break
					
				for j in range(e.y):
					mutex.lock()
					stillAlive = _alive
					mutex.unlock()
					if not stillAlive:
						break
						
					var gridPos = Vector2i(localGridSizeTmp.x * i, localGridSizeTmp.y * j)
					var t = Transform2D(
						deg_to_rad(localMapDataIns.rotation),
						Vector2(gridPos.x + localGridSizeTmp.x / 2.0, 
								gridPos.y + localGridSizeTmp.y / 2.0))
					
					newBuffer[index * 12 + 0] = t.x.x
					newBuffer[index * 12 + 1] = t.x.y
					newBuffer[index * 12 + 2] = 0
					newBuffer[index * 12 + 3] = t.origin.x
					newBuffer[index * 12 + 4] = t.x.y
					newBuffer[index * 12 + 5] = t.y.y
					newBuffer[index * 12 + 6] = 0
					newBuffer[index * 12 + 7] = t.origin.y
					newBuffer[index * 12 + 8] = float(localMapDataIns.buildDefine.atlasTexture.region.position.x)
					newBuffer[index * 12 + 9] = float(localMapDataIns.buildDefine.atlasTexture.region.position.y)
					newBuffer[index * 12 + 10] = float(localMapDataIns.buildDefine.atlasTexture.region.size.x)
					newBuffer[index * 12 + 11] = float(localMapDataIns.buildDefine.atlasTexture.region.size.y)
					index += 1
			
			mutex.lock()
			n = e.x * e.y
			mutex.unlock()
		else:
			mutex.lock()
			var localMapData = curMapData.duplicate(true)  # 深拷贝
			var localGridSizeTmp = _gridSizeTmp
			mutex.unlock()
			
			for mapData in localMapData:
				mutex.lock()
				var stillAlive = _alive
				mutex.unlock()
				if not stillAlive:
					break
					
				var gridPos = mapData.buildAxisPos
				var t = Transform2D(
					deg_to_rad(mapData.rotation),
					Vector2(gridPos.x + localGridSizeTmp.x / 2.0, 
							gridPos.y + localGridSizeTmp.y / 2.0))
				
				newBuffer[index * 12 + 0] = t.x.x
				newBuffer[index * 12 + 1] = t.x.y
				newBuffer[index * 12 + 2] = 0
				newBuffer[index * 12 + 3] = t.origin.x
				newBuffer[index * 12 + 4] = t.x.y
				newBuffer[index * 12 + 5] = t.y.y
				newBuffer[index * 12 + 6] = 0
				newBuffer[index * 12 + 7] = t.origin.y
				newBuffer[index * 12 + 8] = float(mapData.buildDefine.atlasTexture.region.position.x)
				newBuffer[index * 12 + 9] = float(mapData.buildDefine.atlasTexture.region.position.y)
				newBuffer[index * 12 + 10] = float(mapData.buildDefine.atlasTexture.region.size.x)
				newBuffer[index * 12 + 11] = float(mapData.buildDefine.atlasTexture.region.size.y)
				index += 1
			
			mutex.lock()
			n = localMapData.size()
			mutex.unlock()
		
		# 线程安全地获取 n
		mutex.lock()
		var localN = n
		mutex.unlock()
		
		# 使用 call_deferred 传递数据，但 n 通过参数传递
		call_deferred("bufferCalFinish", newBuffer, localN)

func bufferCalFinish(newBuffer:PackedFloat32Array, localN:int) -> void:
	mutex.lock()
	var isAlive = _alive
	mutex.unlock()
	
	if not isAlive:
		return
	
	if not is_instance_valid(self):
		return
	
	if not multimesh or not is_instance_valid(multimesh):
		return
	
	if newBuffer.is_empty():
		return
	
	multimesh.set_buffer(newBuffer)
	multimesh.visible_instance_count = localN
	multimesh.emit_changed()