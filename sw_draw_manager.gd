class_name SWDrawManager extends Node

@onready var color_rect: ColorRect = $TestViewRect

#标准格子大小，如果是地图就需要*2
var _chunkSize:Vector2i = SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE
#区块实例，每个区块位置对应的区块对象
var _chunkInstance:Dictionary[Vector2i,SWDefine.SWDrawChunkData] = {}
#需要绘制区块的任务列表
var _pending_tasks:Dictionary[int,Dictionary] = {}
#记录当前视口大小（初始化为无限大，避免首次更新前删除所有任务）
var _curViewRect:Rect2 = Rect2(-1e9, -1e9, 2e9, 2e9)
#缓存有建筑的 chunk 位置（ByContent 模式专用，避免频繁查询）
var _chunkHasBuildCache:Dictionary[Vector2i,bool] = {}
#缓存是否过期
var _cacheDirty:bool = false
#需要添加到场景的对象
var shouldAddToTree:Array = []
#单纯用来控制每个区块的偏移的缩放
var swTf:SWDefine.SWTransformData

@export var useName:String = ""

var _viewRect:Rect2

@export var _drawMode:SWDefine.GridDrawMode = SWDefine.GridDrawMode.Tiling
@export_range(0, 8, 1) var preLoadwidth: int = 1
@export_range(1, 128, 1) var max_chunks_per_frame: int = 32
#地图相关：地图资源大小
var _blockSize = Vector2(256,256)
#地图相关：使用建筑物信息指定地图的纹理信息
var mapData:SWDefine.SWBuildItemDefine = null
#地图相关：最终传入绘制数据
var mapDataArray:Array[SWDefine.SWBuildItemDefine] = []
#地图相关：地图资源定义
@export var mapDefine:SWBuildDefine = null

var sw_build_manager:SWDefine.SWBuildManager = null
# 方案 2: 降低查询频率
var _queryFrameInterval:int = 1  # 改为每帧更新，消除绘制锯齿感
var _frameCounter:int = 0
func setBuildManager(buildManager:SWDefine.SWBuildManager) -> void:
	sw_build_manager = buildManager
	# 监听建筑变化，标记缓存过期
	if sw_build_manager.build_changed.is_connected(_on_build_changed) == false:
		sw_build_manager.build_changed.connect(_on_build_changed)

func _on_build_changed() -> void:
	_cacheDirty = true
func updataAllChunks() -> void:
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	for chunkPos in _chunkInstance.keys():
		if _chunkInstance.has(chunkPos):
			_chunkInstance[chunkPos].status = SWDefine.ChunkStatus.UNLOADING
		_pending_tasks[0][chunkPos] = false
func updataChunks(chunkPosArr:Array[Vector2i]) -> void:
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	for chunkPos in chunkPosArr:
		if _chunkInstance.has(chunkPos):
			_chunkInstance[chunkPos].status = SWDefine.ChunkStatus.UNLOADING
		_pending_tasks[0][chunkPos] = false
	pass
#TODO _blockSize根据mapDefine来设置



func initDrawMap() -> void:
	_chunkSize=SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE*2
	_blockSize = Vector2(128,128)*2
	if not mapData:
		mapData = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),mapDefine)
		mapData.rotation = SWCommon.GetAngleBySWDir(SWDefine.SW_Dir.UP)
		mapDataArray.append(mapData)
	
func initDrawContent() -> void:
	_chunkSize=SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE
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
	# 方案 2: 降低查询频率，每 3 帧执行一次
	_frameCounter += 1
	if _frameCounter % _queryFrameInterval != 0:
		return
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
	#print(useName,"keys size:",keys.size())
	for chunkPos in keys:
		if not _curViewRect.has_point(chunkPos) and (_drawMode != SWDefine.GridDrawMode.ByHold and _drawMode != SWDefine.GridDrawMode.HoldShadow):
			_pending_tasks[priority].erase(chunkPos)
			continue
		if _drawMode == SWDefine.GridDrawMode.ByContent:
			var chunkBuilds = sw_build_manager.getBuildsByChunkPos(chunkPos)
			if chunkBuilds.size() == 0:
				tasks.erase(chunkPos)
				continue
			mapDataArray = chunkBuilds
		if count >= max_chunks_per_frame and _drawMode == SWDefine.GridDrawMode.Tiling:
			break
		if _chunkInstance.has(chunkPos):
			tasks.erase(chunkPos)
			continue
		count+=1
		var chunkIns = SWObjectPool.GetSWChunkDataObject(_drawMode)
		chunkIns.chunk_pos = chunkPos
		if _drawMode == SWDefine.GridDrawMode.ByContent:
			swTf.offset = Vector2(0,0)
		else:
			swTf.offset = Vector2(chunkPos.x,chunkPos.y)
			
		chunkIns.mesh_instance.setMeshSize(_blockSize)
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		chunkIns.mesh_instance.setDrawMode(_drawMode)
		chunkIns.mesh_instance.drawMap(mapDataArray)
		
		_chunkInstance[chunkPos] = chunkIns
		# 对象池复用时 mesh_instance 可能仍在树上：
		# - 已经在当前 SWDrawManager 下：不要重复 add_child
		# - 在其他父节点下：先脱离再挂到当前节点
		var mi: SWMultiMeshInstance2D = chunkIns.mesh_instance
		var mi_parent: Node = mi.get_parent()
		if mi_parent != null and mi_parent != self:
			mi_parent.remove_child(mi)
			mi_parent = null
		if mi_parent == null:
			shouldAddToTree.append(mi)
		mi.visible = true
		mi.set_process(true)
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

func _updateChunkCache(viewRect:Rect2) -> void:
	if _drawMode != SWDefine.GridDrawMode.ByContent:
		return
	## 只在缓存过期时更新
	#if not _cacheDirty:
		#return
	#_cacheDirty = false
	_chunkHasBuildCache.clear()
	var mmiCount = getNeedCountOfMMI(viewRect)
	var bPos = (viewRect.position/Vector2(_chunkSize))
	var beginChunkPos:Vector2i = floor(bPos)*Vector2(_chunkSize)
	# 只查询视口内的 chunk，批量获取
	for x in range(mmiCount.x):
		for y in range(mmiCount.y):
			var chunkPos = Vector2i(beginChunkPos.x+x*_chunkSize.x,beginChunkPos.y+y*_chunkSize.y)
			if sw_build_manager.getBuildCountByChunkPos(chunkPos) > 0:
				_chunkHasBuildCache[chunkPos] = true

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
	# 更新缓存（只在 ByContent 模式且缓存过期时查询）
	_updateChunkCache(viewRect)
	for x in range(mmiCount.x):
		for y in range(mmiCount.y):
			var chunkPos = Vector2i(beginChunkPos.x+x*_chunkSize.x,beginChunkPos.y+y*_chunkSize.y)
			if not _chunkInstance.has(chunkPos):
				if _drawMode == SWDefine.GridDrawMode.ByContent:
					# 使用缓存，避免重复查询
					if _chunkHasBuildCache.has(chunkPos):
						_pending_tasks[0][chunkPos]=false
				else:
					_pending_tasks[0][chunkPos]=false
	
	if _drawMode == SWDefine.GridDrawMode.Tiling:
		# 预加载范围按“区块圈数”扩展，而不是按“视口像素尺寸倍数”扩展
		var preloadBeginChunkPos: Vector2 = beginChunkPos - mmiCount*_chunkSize*preLoadwidth#Vector2(preLoadwidth * _chunkSize.x, preLoadwidth * _chunkSize.y)
		var preloadMmiCount: Vector2i = mmiCount*(1+2*preLoadwidth)# + Vector2i(2 * preLoadwidth, 2 * preLoadwidth)
		
		var speedVecTmp = speedVec#.normalized()
		#speedVecTmp/=speedVecTmp
		if speedVecTmp.x != 0:
			speedVecTmp.x/=abs(speedVecTmp.x)
		if speedVecTmp.y != 0:
			speedVecTmp.y/=abs(speedVecTmp.y)
		preloadMmiCount+=Vector2i(speedVecTmp)*mmiCount
		for x in range(preloadMmiCount.x):
			for y in range(preloadMmiCount.y):
				#var chunkPos = Vector2i(preloadBeginChunkPos.x+(x+speedVecTmp.x)*_chunkSize.x,preloadBeginChunkPos.y+(y+speedVecTmp.y)*_chunkSize.y)
				var chunkPos = Vector2i(preloadBeginChunkPos.x+(x)*_chunkSize.x,preloadBeginChunkPos.y+(y)*_chunkSize.y)
				if not _chunkInstance.has(chunkPos) and not _pending_tasks[0].has(chunkPos):
					_pending_tasks[1][chunkPos]=false
					#print("Preload: ", chunkPos)
		var delShowInsRect = Rect2(showInsRect.position-showInsRect.size,showInsRect.size*3)
		_curViewRect = delShowInsRect
		for chunkPos in _chunkInstance.keys():
			if not delShowInsRect.has_point(chunkPos):
				_chunkInstance[chunkPos].status = SWDefine.ChunkStatus.UNLOADING
	else:
		var delShowInsRect = Rect2(showInsRect.position,showInsRect.size)
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
func getHoldBuild() -> SWDrawData:
	return _drawData
func getHoldCenter() -> Vector2:
	return _center_offset
	
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
		mapDataArray = drawData.mapDatas
		var maxPos:Vector2
		var minPos:Vector2
		for mapData in mapDataArray:
			var chunkPos = SWCommon.GetChunkPos(mapData.buildAxisPos)
			_pending_tasks[2][chunkPos] = false
			if not caled:
				caled = true
				minPos = Vector2(mapData.buildAxisPos)
				maxPos = Vector2(mapData.buildAxisPos)+_blockSize
			else:
				minPos.x = min(mapData.buildAxisPos.x,minPos.x)
				minPos.y = min(mapData.buildAxisPos.y,minPos.y)
				maxPos.x = max(mapData.buildAxisPos.x+_blockSize.x,maxPos.x)
				maxPos.y = max(mapData.buildAxisPos.y+_blockSize.y,maxPos.y)
		centerRect.position = minPos
		centerRect.end = maxPos
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
