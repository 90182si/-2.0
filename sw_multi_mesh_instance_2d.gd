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
var semaphore: Semaphore

func setDrawMode(mode:SWDefine.GridDrawMode) -> void:
	_drawMode = mode

func resetOffsetAndScale(_swTf:SWDefine.SWTransformData) -> void:
	_swTransform = _swTf
	position = _swTransform.offset
	#scale = _swTransform.scale
	
	(multimesh.mesh as QuadMesh).set_size(Vector2(_gridSize.x, -_gridSize.y)*_swTransform.scale)

func setMeshSize(size:Vector2) -> void:
	_gridSize = size
	(multimesh.mesh as QuadMesh).set_size(Vector2(size.x, -size.y))
	
func _exit_tree() -> void:
	alive = false
	semaphore.post()
	thread.wait_to_finish()

func _init() -> void:
	_swTransform = SWDefine.SWTransformData.new()
	thread = Thread.new()
	semaphore = Semaphore.new()
	multimesh.instance_count = n
	thread.start(calBuffer)
	
var mapDataIns:SWDefine.SWBuildItemDefine = null
var gridSizeTmp:Vector2

var hadDraw = false
func drawMap(mapData:Array[SWDefine.SWBuildItemDefine],_flashDrawRegion:bool = false) -> void:
	#var thread_start = Time.get_ticks_msec()
	gridSizeTmp = _gridSize*_swTransform.scale
	var bs = floor(-_swTransform.offset/gridSizeTmp)
	var _b = _swTransform.offset+bs*gridSizeTmp
	if _drawMode == SWDefine.GridDrawMode.ByContent or _drawMode == SWDefine.GridDrawMode.ByHold or _drawMode == SWDefine.GridDrawMode.HoldShadow:
		var mapDataTmp:Array[SWDefine.SWBuildItemDefine]
		for i in range(mapData.size()):
			mapDataIns = mapData[i]
			if mapDataIns.buildAxisPos.x < bs.x or mapDataIns.buildAxisPos.y < bs.y:
				continue
			if mapDataIns.buildAxisPos.x > bs.x+e.x or mapDataIns.buildAxisPos.y > bs.y + e.y:
				continue
			mapDataTmp.append(mapDataIns)
		multimesh.instance_count = mapDataTmp.size()
		buffer = multimesh.get_buffer()
		for i in range(multimesh.instance_count):
			mapDataIns = mapDataTmp[i]
			var t = Transform2D(mapDataIns.rotation,
				Vector2(mapDataIns.buildAxisPos.x * gridSizeTmp.x+gridSizeTmp.x/2.0, 
						mapDataIns.buildAxisPos.y * gridSizeTmp.y+gridSizeTmp.y/2.0))
			buffer[i*12+0] = t.x.x
			buffer[i*12+1] = t.y.x
			buffer[i*12+2] = 0
			buffer[i*12+3] = t.origin.x
			buffer[i*12+4] = t.x.y
			buffer[i*12+5] = t.y.y
			buffer[i*12+6] = 0
			buffer[i*12+7] = t.origin.y
			buffer[i*12+8] = float(mapDataIns.buildDefine.atlasTexture.region.position.x)
			buffer[i*12+9] = float(mapDataIns.buildDefine.atlasTexture.region.position.y)
			buffer[i*12+10] = float(mapDataIns.buildDefine.atlasTexture.region.size.x)
			buffer[i*12+11] = float(mapDataIns.buildDefine.atlasTexture.region.size.y)
		multimesh.set_buffer(buffer)
		multimesh.emit_changed()
		multimesh.visible_instance_count = multimesh.instance_count
	elif _drawMode == SWDefine.GridDrawMode.Tiling:
		if hadDraw:
			return
		if mapData.size()==0:
			print("显示模式为Tiling，但是mapData数据为空")
			return
		mapDataIns = mapData[0]
		if buffer.size() == 0:
			buffer = multimesh.get_buffer()
		hasNewPlan = true
		semaphore.post()
	pass

func calBuffer() -> void:
	while alive:
		semaphore.wait()
		if not alive:
			continue
		var index = 0
		for i in range(e.x):
			if stopThread:
				break
			for j in range(e.y):
				if stopThread:
					break
				var gridPos = Vector2i(i,j)
				var t = Transform2D(
					deg_to_rad(mapDataIns.rotation),
					Vector2(gridPos.x * gridSizeTmp.x+gridSizeTmp.x/2.0, 
							gridPos.y * gridSizeTmp.y+gridSizeTmp.y/2.0))
				buffer[index*12+0] = t.x.x
				buffer[index*12+1] = t.y.x
				buffer[index*12+2] = 0
				buffer[index*12+3] = t.origin.x
				buffer[index*12+4] = t.x.y
				buffer[index*12+5] = t.y.y
				buffer[index*12+6] = 0
				buffer[index*12+7] = t.origin.y
				buffer[index*12+8] = float(mapDataIns.buildDefine.atlasTexture.region.position.x)
				buffer[index*12+9] = float(mapDataIns.buildDefine.atlasTexture.region.position.y)
				buffer[index*12+10] = float(mapDataIns.buildDefine.atlasTexture.region.size.x)
				buffer[index*12+11] = float(mapDataIns.buildDefine.atlasTexture.region.size.y)
				index += 1
		call_deferred("bufferCalFinish")

func bufferCalFinish()->void:
	#hadDraw = true
	if not is_instance_valid(self):
		return
	
	multimesh.set_buffer(buffer)
	multimesh.emit_changed()
	multimesh.visible_instance_count = n
