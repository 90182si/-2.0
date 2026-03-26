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
		multimesh.instance_count = n
	thread.start(calBuffer)
	
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
	if buffer.size() == 0:
		buffer = multimesh.get_buffer()
		bufferSize = buffer.size()
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
		newBuffer.resize(bufferSize)
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
			showCount = e.x*e.y
		else:
			for mapData in curMapData:
				var gridPos = mapData.buildAxisPos
				var t = Transform2D(
					deg_to_rad(mapData.rotation),
					Vector2(gridPos.x + _gridSizeTmp.x / 2.0, 
							gridPos.y + _gridSizeTmp.y / 2.0))
				
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
			showCount = curMapData.size()
		# 使用 call_deferred 传递数据，但 n 通过参数传递
		call_deferred("bufferCalFinish", newBuffer, showCount)
		planIsRunning = false

func bufferCalFinish(newBuffer:PackedFloat32Array, localN:int) -> void:
	multimesh.set_buffer(newBuffer)
	multimesh.visible_instance_count = localN
	multimesh.emit_changed()
