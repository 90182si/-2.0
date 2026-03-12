class_name SWDrawManager extends Node

@onready var color_rect: ColorRect = $TestViewRect

#标准格子大小，如果是地图就需要*2
var _chunkSize:Vector2i = SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE
#区块实例，每个区块位置对应的区块对象
var _chunkInstance:Dictionary[Vector2i,SWDefine.SWDrawChunkData] = {}
#需要绘制区块的任务列表
var _pending_tasks:Dictionary[int,Dictionary] = {}
#记录当前视口大小
var _curViewRect:Rect2 = Rect2(0,0,0,0)
#需要添加到场景的对象
var shouldAddToTree:Array = []
#单纯用来控制每个区块的偏移的缩放
var swTf:SWDefine.SWTransformData

var _viewRect:Rect2

@export var _drawMode:SWDefine.GridDrawMode = SWDefine.GridDrawMode.Tiling
@export_range(0, 8, 1) var preLoadwidth: int = 1
@export_range(1, 128, 1) var max_chunks_per_frame: int = 8
#地图相关：地图资源大小
var _blockSize = Vector2(256,256)
#地图相关：使用建筑物信息指定地图的纹理信息
var mapData:SWDefine.SWBuildItemDefine = null
#地图相关：最终传入绘制数据
var mapDataArray:Array[SWDefine.SWBuildItemDefine] = []
#地图相关：地图资源定义
@export var mapDefine:SWBuildDefine = null

#TODO _blockSize根据mapDefine来设置

func initDrawMap() -> void:
	_chunkSize=SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE*2
	if not mapData:
		mapData = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),mapDefine)
		mapData.rotation = SWCommon.GetAngleBySWDir(SWDefine.SW_Dir.UP)
		mapDataArray.append(mapData)
	
func initDrawContent() -> void:
	_blockSize = Vector2(128,128)
	pass
	
func setDrawMode(drawMode:SWDefine.GridDrawMode) -> void:
	_drawMode = drawMode
	if _drawMode == SWDefine.GridDrawMode.Tiling:
		initDrawMap()
	else:
		initDrawContent()
	pass
	
func _ready() -> void:
	if not mapDefine:
		assert(false, "mapDefine未定义")
	swTf = SWDefine.SWTransformData.new()
	setDrawMode(_drawMode)

func _process(_delta: float) -> void:
	process_unload_chunk()
	shouldAddToTree.clear()
	process_load_chunk(0)
	process_load_chunk(1)
	process_load_chunk(2,false)
	for ins in shouldAddToTree:
		add_child(ins)
	pass
	
func process_load_chunk(priority:int,remove:bool = true) -> void:
	if not _pending_tasks.has(priority):
		return
	var tasks: Dictionary = _pending_tasks[priority]
	var count = 0
	var keys := tasks.keys()
	for chunkPos in keys:
		if not _curViewRect.has_point(chunkPos) and (_drawMode != SWDefine.GridDrawMode.ByHold and _drawMode != SWDefine.GridDrawMode.HoldShadow):
			_pending_tasks[priority].erase(chunkPos)
			continue
		if count >= max_chunks_per_frame:
			break
		if _chunkInstance.has(chunkPos):
			tasks.erase(chunkPos)
			continue
		count+=1
		var chunkIns = SWObjectPool.GetSWChunkDataObject()
		chunkIns.chunk_pos = chunkPos
		chunkIns.mesh_instance.setMeshSize(_blockSize)
		swTf.offset = Vector2(chunkPos.x,chunkPos.y)
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		chunkIns.mesh_instance.setDrawMode(_drawMode)
		chunkIns.mesh_instance.drawMap(mapDataArray)
		
		_chunkInstance[chunkPos] = chunkIns
		if chunkIns.status == SWDefine.ChunkStatus.EMPTY:
			shouldAddToTree.append(chunkIns.mesh_instance)
			chunkIns.status = SWDefine.ChunkStatus.FULLY_LOADED
		else:
			chunkIns.mesh_instance.visible = true
			chunkIns.mesh_instance.set_process(true)
			chunkIns.status = SWDefine.ChunkStatus.FULLY_LOADED
		tasks.erase(chunkPos)

	if tasks.is_empty() and not _draging:
		_pending_tasks.erase(priority)
func process_unload_chunk() -> void:
	var forDelPosArr = []
	for chunkIns:SWDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.status != SWDefine.ChunkStatus.UNLOADING:
			continue
		chunkIns.status = SWDefine.ChunkStatus.UNLOADED
		chunkIns.status = SWDefine.ChunkStatus.UNVISIBLE
		chunkIns.mesh_instance.set_process(false)
		chunkIns.mesh_instance.visible = false
		forDelPosArr.append(chunkIns.chunk_pos)
		SWObjectPool.DelSWChunkDataObject(chunkIns)
	for pos in forDelPosArr:
		_chunkInstance.erase(pos)

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	color_rect.position = viewRect.position
	color_rect.size = viewRect.size
	var mmiCount = getNeedCountOfMMI(viewRect)
	var bPos = (viewRect.position/Vector2(_chunkSize))
	var beginChunkPos:Vector2i = floor(bPos)*Vector2(_chunkSize)
	var showInsRect = Rect2(beginChunkPos,Vector2(mmiCount)*Vector2(_chunkSize))
	if _drawMode == SWDefine.GridDrawMode.ByHold or _drawMode == SWDefine.GridDrawMode.HoldShadow:
		return
	#_curViewRect = showInsRect
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	if not _pending_tasks.has(1):
		_pending_tasks[1] = {}
	for x in range(mmiCount.x):
		for y in range(mmiCount.y):
			var chunkPos = Vector2i(beginChunkPos.x+x*_chunkSize.x,beginChunkPos.y+y*_chunkSize.y)
			if not _chunkInstance.has(chunkPos):
				_pending_tasks[0][chunkPos]=false
	
	# 预加载范围按“区块圈数”扩展，而不是按“视口像素尺寸倍数”扩展
	var preloadBeginChunkPos: Vector2 = beginChunkPos - mmiCount*_chunkSize*preLoadwidth#Vector2(preLoadwidth * _chunkSize.x, preLoadwidth * _chunkSize.y)
	var preloadMmiCount: Vector2i = mmiCount*(1+2*preLoadwidth)# + Vector2i(2 * preLoadwidth, 2 * preLoadwidth)
	
	var speedVecTmp = speedVec#.normalized()
	#speedVecTmp/=speedVecTmp
	if speedVecTmp.x != 0:
		speedVecTmp.x/=abs(speedVecTmp.x)
	if speedVecTmp.y != 0:
		speedVecTmp.y/=abs(speedVecTmp.y)
	for x in range(preloadMmiCount.x):
		for y in range(preloadMmiCount.y):
			var chunkPos = Vector2i(preloadBeginChunkPos.x+(x+speedVecTmp.x)*_chunkSize.x,preloadBeginChunkPos.y+(y+speedVecTmp.y)*_chunkSize.y)
			if not _chunkInstance.has(chunkPos) and not _pending_tasks[0].has(chunkPos):
				_pending_tasks[1][chunkPos]=false
				#print("Preload: ", chunkPos)
	var delShowInsRect = Rect2(showInsRect.position-showInsRect.size,showInsRect.size*3)
	_curViewRect = delShowInsRect
	for chunkPos in _chunkInstance.keys():
		if not delShowInsRect.has_point(chunkPos):
			_chunkInstance[chunkPos].status = SWDefine.ChunkStatus.UNLOADING
	pass

func getNeedCountOfMMI(rect:Rect2) -> Vector2i:
	var bPos = (rect.position/Vector2(_chunkSize))
	var beginChunkPos = floor(bPos)*Vector2(_chunkSize)
	var endChunkPos = (rect.end/Vector2(_chunkSize)).ceil()*Vector2(_chunkSize)
	var size = (endChunkPos-beginChunkPos)/Vector2(_chunkSize)
	return size

var _drawData:SWDrawData = null
var _draging:bool = false
var _center_offset:Vector2
func setHoldBuild(drawData:SWDrawData) -> void:
	for chunkIns:SWDefine.SWDrawChunkData in _chunkInstance.values():
		chunkIns.status = SWDefine.ChunkStatus.UNLOADING
	_drawData = drawData
	var centerRect:Rect2=Rect2(0,0,0,0)
	var caled = false
	if _drawData:
		_draging = true
		
		if not _pending_tasks.has(2):
			_pending_tasks[2] = {}
		_pending_tasks[2][Vector2i(0,0)] = false
		mapDataArray = drawData.mapDatas
		for mapData in mapDataArray:
			if not caled:
				caled = true
				centerRect.position = Vector2(mapData.buildAxisPos)
				centerRect.end = Vector2(mapData.buildAxisPos)+_blockSize
			else:
				centerRect.position.x = min(mapData.buildAxisPos.x*_blockSize.x,centerRect.position.x)
				centerRect.position.y = min(mapData.buildAxisPos.y*_blockSize.y,centerRect.position.y)
				centerRect.end.x = max(mapData.buildAxisPos.x*_blockSize.x+_blockSize.x,centerRect.end.x)
				centerRect.end.y = max(mapData.buildAxisPos.y*_blockSize.y+_blockSize.y,centerRect.end.y)
		_center_offset = centerRect.get_center()
	else:
		_draging = false
		_pending_tasks.clear()
	pass

func setHoldBuildsPos(mousePos:Vector2) -> void:
	if not _draging:
		return
	for chunkIns:SWDefine.SWDrawChunkData in _chunkInstance.values():
		swTf.offset = mousePos - _center_offset
		if _drawMode == SWDefine.GridDrawMode.HoldShadow:
			swTf.offset = SwCommon.GetGridPos(swTf.offset+_blockSize/2)
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		pass
	pass
