class_name SWMultiMeshInstance2D extends MultiMeshInstance2D

var _swTransform:SWDefine.SWTransformData
var _gridSize:Vector2 = SWDefine.GRID_SIZE
var _drawMode:SWDefine.GridDrawMode=SWDefine.GridDrawMode.Tiling

var chunkPtr:SWDefine.SWDrawChunkData = null
var thread:Thread = null
var buffer:PackedFloat32Array
var stopThread = 0
var alive = true
var hasNewPlan = false
var e = Vector2i(SWDefine.CHUNK_SIZE,SWDefine.CHUNK_SIZE)#floor((_drawRect.end-b)/gridSizeTmp)+Vector2(1,1)
var n = e.x*e.y	
var planIsRunning = false
var mutex:Mutex
var semaphore: Semaphore

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
	#scale = _swTransform.scale
	
	(multimesh.mesh as QuadMesh).set_size(Vector2(_gridSize.x, -_gridSize.y)*_swTransform.scale)

func setMeshSize(size:Vector2) -> void:
	_gridSize = size
	(multimesh.mesh as QuadMesh).set_size(Vector2(size.x, -size.y))
	
func _exit_tree() -> void:
	if not alive:
		return
	alive = false
	semaphore.post()
	if thread and thread.is_started():
		thread.wait_to_finish()

func _init() -> void:
	_swTransform = SWDefine.SWTransformData.new()
	thread = Thread.new()
	semaphore = Semaphore.new()
	mutex = Mutex.new()
	multimesh.instance_count = n
	thread.start(calBuffer)
	
var mapDataIns:SWDefine.SWBuildItemDefine = null
var gridSizeTmp:Vector2

var hadDraw = false
var curMapData:Array[SWDefine.SWBuildItemDefine]
var bufferSize = 0
func drawMap(mapData:Array[SWDefine.SWBuildItemDefine],_flashDrawRegion:bool = false) -> void:
	gridSizeTmp = _gridSize*_swTransform.scale
	if hadDraw and _drawMode == SWDefine.GridDrawMode.Tiling:
		return
	mutex.lock()
	curMapData = mapData
	mutex.unlock()
	mutex.lock()
	if buffer.size() == 0:
		buffer = multimesh.get_buffer()
		bufferSize = buffer.size()
	mutex.unlock()
	hasNewPlan = true
	semaphore.post()
	pass

func calBuffer() -> void:
	while alive:
		semaphore.wait()
		if not alive:
			continue
		var index = 0
		var newBuffer:PackedFloat32Array
		newBuffer.resize(bufferSize)
		if _drawMode == SWDefine.GridDrawMode.Tiling:
			var localMapDataIns:SWDefine.SWBuildItemDefine
			mutex.lock()
			if curMapData.is_empty():
				mutex.unlock()
				continue
			localMapDataIns = curMapData[0]
			mutex.unlock()
			for i in range(e.x):
				if stopThread or not alive:
					break
				for j in range(e.y):
					if stopThread or not alive:
						break
					var gridPos = Vector2i(gridSizeTmp.x*i,gridSizeTmp.y*j)
					var t = Transform2D(
						deg_to_rad(localMapDataIns.rotation),
						Vector2(gridPos.x+gridSizeTmp.x/2.0, 
								gridPos.y+gridSizeTmp.y/2.0))
					newBuffer[index*12+0] = t.x.x
					newBuffer[index*12+1] = t.y.x
					newBuffer[index*12+2] = 0
					newBuffer[index*12+3] = t.origin.x
					newBuffer[index*12+4] = t.x.y
					newBuffer[index*12+5] = t.y.y
					newBuffer[index*12+6] = 0
					newBuffer[index*12+7] = t.origin.y
					newBuffer[index*12+8] = float(localMapDataIns.buildDefine.atlasTexture.region.position.x)
					newBuffer[index*12+9] = float(localMapDataIns.buildDefine.atlasTexture.region.position.y)
					newBuffer[index*12+10] = float(localMapDataIns.buildDefine.atlasTexture.region.size.x)
					newBuffer[index*12+11] = float(localMapDataIns.buildDefine.atlasTexture.region.size.y)
					index += 1
			n = e.x*e.y
		else:
			var localMapData:Array[SWDefine.SWBuildItemDefine]
			mutex.lock()
			localMapData = curMapData.duplicate()
			mutex.unlock()
			for mapData in localMapData:
				if stopThread or not alive:
					break
				var gridPos = mapData.buildAxisPos#-Vector2i(_swTransform.offset)
				var t = Transform2D(
					deg_to_rad(mapData.rotation),
					Vector2(gridPos.x+gridSizeTmp.x/2.0, 
							gridPos.y+gridSizeTmp.y/2.0))
				newBuffer[index*12+0] = t.x.x
				newBuffer[index*12+1] = t.y.x
				newBuffer[index*12+2] = 0
				newBuffer[index*12+3] = t.origin.x
				newBuffer[index*12+4] = t.x.y
				newBuffer[index*12+5] = t.y.y
				newBuffer[index*12+6] = 0
				newBuffer[index*12+7] = t.origin.y
				newBuffer[index*12+8] = float(mapData.buildDefine.atlasTexture.region.position.x)
				newBuffer[index*12+9] = float(mapData.buildDefine.atlasTexture.region.position.y)
				newBuffer[index*12+10] = float(mapData.buildDefine.atlasTexture.region.size.x)
				newBuffer[index*12+11] = float(mapData.buildDefine.atlasTexture.region.size.y)
				index+=1
			n = localMapData.size()
		call_deferred("bufferCalFinish",newBuffer)

func bufferCalFinish(newBuffer:PackedFloat32Array)->void:
	if not alive or not is_instance_valid(self) or not is_instance_valid(multimesh):
		return
	if newBuffer.is_empty():
		return
	
	multimesh.set_buffer(newBuffer)
	multimesh.emit_changed()
	multimesh.visible_instance_count = n
