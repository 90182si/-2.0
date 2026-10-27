class_name SWDrawManager extends Node

@onready var color_rect: ColorRect = $TestViewRect

#标准格子大小，如果是地图就需要*2
var _chunkSize:Vector2i = SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE
#区块实例，每个区块位置对应的区块对象
var _chunkInstance:Dictionary[Vector2i,SwDefine.SWDrawChunkData] = {}
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
var swTf:SwDefine.SWTransformData

@export var useName:String = ""

var _viewRect:Rect2
#本绘制层的可见状态：作用于所有区块 mesh 实例，并对之后新加载的区块同样生效
var _visible:bool = true

@export var _drawMode:SwDefine.GridDrawMode = SwDefine.GridDrawMode.Tiling
@export_range(0, 8, 1) var preLoadwidth: int = 1
@export_range(1, 128, 1) var max_chunks_per_frame: int = 32
# 异步加载：ByContent 模式分帧加载区块，保证帧率；关闭则一帧加载所有（可能卡顿但立即显示）
var async_loading: bool = true
# 异步模式下 ByContent 每帧最多加载的区块数（需不小于快速移动时单帧轮换的数量）
@export_range(1, 64, 1) var async_chunks_per_frame: int = 12
# 视口外保留的区块圈数：相机在区块边界来回移动时不再反复卸载/重建
@export_range(0, 3, 1) var unload_margin_chunks: int = 1
# 每帧最多卸载的区块数：缩小视角时视口一次覆盖上百个区块，一次全部卸载会在单帧卡顿上百毫秒
@export_range(1, 64, 1) var max_unloads_per_frame: int = 16
# ByContent 模式下卸下后仍保留渲染节点、CPU 缓冲与槽位表的区块数量上限（0 表示不保留）。
# 相机移动时区块边界持续轮换，保留这些状态可免去重新创建节点与整块重建
@export_range(0, 2048, 16) var idle_chunk_cache_size: int = 128
#地图相关：地图资源大小
var _blockSize = Vector2(256,256)
#地图相关：使用建筑物信息指定地图的纹理信息
var mapData:SWBuildItemDefine = null
#地图相关：最终传入绘制数据
var mapDataArray:Array[SWBuildItemDefine] = []
#地图相关：地图资源定义
@export var mapDefine:SWBuildDefine = null

var sw_build_manager:SWBuildManager = null
# 已卸载但保留渲染节点的区块：chunkPos -> 区块数据（仅 ByContent 使用，作为按需淘汰的软缓存）
var _idleChunkCache:Dictionary[Vector2i, SwDefine.SWDrawChunkData] = {}
# 软缓存的插入顺序，用于超限时淘汰最旧的区块
var _idleChunkOrder:Array[Vector2i] = []
# 本节拍同时在后台构建的区块数，供三个优先级队列共用
var _buildingChunksNow:int = 0
# 方案 2: 降低查询频率
var _queryFrameInterval:int = 1  # 改为每帧更新，消除绘制锯齿感
var _frameCounter:int = 0
# 本帧触发重绘（调用 drawMap 重建 buffer）的区块数与上一帧快照，供性能面板读取
var _redraw_chunks_frame:int = 0
var _redraw_chunks_last:int = 0
# 本帧退回整块重建的区块数：增量补丁失败（槽位/部件数变了）才会走这里，
# 正常情况下应保持接近 0，异常升高说明补丁路径没命中
var _full_rebuilds_frame:int = 0
# 待增量补丁的区块、各区块的待补丁建筑、以及尚未落地的翻转 net（跨帧累积，幂等）
var _patch_queue:Dictionary[Vector2i,bool] = {}
var _patch_builds:Dictionary = {}      # Vector2i -> Dictionary[build,bool]
var _patch_nets:Dictionary = {}        # net -> true
# 内容变了（增删建筑/底色）的区块：槽位表已不可信，必须整块重建而不是增量回写
var _rebuild_queue:Dictionary[Vector2i,bool] = {}
# 主线程同步构建/补丁的时间预算（微秒）：超出就留到下一帧继续，避免单帧长卡顿。
# 补丁预算每帧会被消费两次（信号级联当帧一次、_process 补一次），所以按半帧的量给
const BUILD_BUDGET_USEC:int = 8000
const PATCH_BUDGET_USEC:int = 4000

# 上一帧需要重绘的区块数量
func get_redraw_chunks_per_frame() -> int:
	return _redraw_chunks_last

# 上一帧退回整块重建的区块数（增量补丁未命中）
func get_full_rebuilds_last_frame() -> int:
	return _full_rebuilds_frame
func setBuildManager(buildManager:SWBuildManager) -> void:
	sw_build_manager = buildManager
	# 监听建筑变化，标记缓存过期
	if sw_build_manager.build_changed.is_connected(_on_build_changed) == false:
		sw_build_manager.build_changed.connect(_on_build_changed)

func _on_build_changed() -> void:
	_cacheDirty = true
func updataAllChunks() -> void:
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	# 全量刷新：所有区块都会重建，挂起的增量补丁与累积的脏 net 作废
	_patch_queue.clear()
	_patch_builds.clear()
	_patch_nets.clear()
	_rebuild_queue.clear()
	for chunkPos in _chunkInstance.keys():
		if not _chunkInstance.has(chunkPos):
			continue
		var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			# 内容层原地重建：旧内容先留着，按时间预算分帧换成新内容。
			# 不能走「卸载→重加载」：卸载有每帧上限，期间的加载任务会因为区块还留在
			# _chunkInstance 里被丢掉，区块就一直显示刷新前的旧建筑（换存档后残留）
			_patch_queue[chunkPos] = true
			_rebuild_queue[chunkPos] = true
			continue
		chunkIns.status = SwDefine.ChunkStatus.UNLOADING
		_pending_tasks[0][chunkPos] = false
	_flush_patches(PATCH_BUDGET_USEC)
#changedBuilds：本次信号变化涉及的元件（门/灯/寄存器/开关）。
#dirtyNets：本次翻转电平的 net 集合（连线换色走批量索引，不逐根进补丁列表）。
#两者都为空表示这是「内容变了」（放置/删除/剪切/选中底色），区块里的建筑集合或
#底色都可能对不上已有槽位，必须整块重建内容；否则走增量补丁。
#两类刷新都按时间预算分帧处理：一次信号级联会覆盖数百个区块，全挤在一帧会拉出长帧。
func updataChunks(chunkPosArr:Array[Vector2i], changedBuilds:Array = [], dirtyNets:Dictionary = {}) -> void:
	if not _pending_tasks.has(0):
		_pending_tasks[0] = {}
	var contentChanged:bool = changedBuilds.is_empty() and dirtyNets.is_empty()
	for net in dirtyNets:
		_patch_nets[net] = true
	for build:SWBuildItemDefine in changedBuilds:
		if build == null:
			continue
		var cp:Vector2i = SwCommon.GetChunkPos(build.buildAxisPos)
		var group:Dictionary = _patch_builds.get(cp, {})
		group[build] = true
		_patch_builds[cp] = group
	for chunkPos in chunkPosArr:
		if _chunkInstance.has(chunkPos):
			_patch_queue[chunkPos] = true
			if contentChanged:
				_rebuild_queue[chunkPos] = true
			continue
		# 新区块：加入待加载任务
		_pending_tasks[0][chunkPos] = false
		# 该区块此刻可能正躺在软缓存里：其内容已变（状态翻转/增删建筑），
		# 必须失效缓存条目的 builtVersion，否则下次进视口会 reuse 旧 buffer 跳过重绘
		if _idleChunkCache.has(chunkPos):
			_idleChunkCache[chunkPos].mesh_instance.builtVersion = -1
	_flush_patches(PATCH_BUDGET_USEC)

# 分帧处理待刷新区块；补丁按「当前状态」回写，重复执行是幂等的，
# 因此跨帧/跨级联累积都安全，未处理完的留到下一帧继续
func _flush_patches(budget_usec:int) -> void:
	if _patch_queue.is_empty():
		_patch_nets.clear()
		return
	var start:int = Time.get_ticks_usec()
	var done:Array[Vector2i] = []
	for chunkPos:Vector2i in _patch_queue:
		if Time.get_ticks_usec() - start > budget_usec:
			break
		done.append(chunkPos)
		if _rebuild_queue.has(chunkPos):
			_refreshChunkContent(chunkPos)
			continue
		var builds:Dictionary = _patch_builds.get(chunkPos, {})
		_patch_builds.erase(chunkPos)
		if not _patch_chunk(chunkPos, builds):
			_refreshChunkContent(chunkPos)
	for chunkPos in done:
		_patch_queue.erase(chunkPos)
		_rebuild_queue.erase(chunkPos)
	if _patch_queue.is_empty():
		_patch_nets.clear()

# 返回 false 表示该区块无法增量回写（无 CPU buffer / 槽位对不上），需要整块重建
func _patch_chunk(chunkPos:Vector2i, builds:Dictionary) -> bool:
	if not _chunkInstance.has(chunkPos):
		return true
	var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
	if chunkIns.status != SwDefine.ChunkStatus.FULLY_LOADED:
		return true
	var mi:SWMultiMeshInstance2D = chunkIns.mesh_instance
	if not mi.hasCpuBuffer():
		return false
	var touched:bool = false
	if not builds.is_empty():
		if not mi.patchBuilds(builds.keys()):
			return false
		touched = true
	if not _patch_nets.is_empty() and mi.patchNets(_patch_nets):
		touched = true
	if touched:
		mi.flushPatch()
		_redraw_chunks_frame += 1
	return true

# 直接刷新已有区块的绘制内容（不卸载、不隐藏，旧内容继续显示直到新buffer就绪）
func _refreshChunkContent(chunkPos:Vector2i) -> void:
	if not _chunkInstance.has(chunkPos):
		return
	var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
	
	if _drawMode == SwDefine.GridDrawMode.ByContent:
		var dirtyBuilds = sw_build_manager.getBuildsByChunkPos(chunkPos)
		if dirtyBuilds.size() == 0:
			# 区块已经没有建筑了：只隐藏，状态保持 FULLY_LOADED。
			# 这里若转成 UNLOADING，视口内的区块会被 on_view_rect_changed 复活，
			# 旧建筑的 buffer 又原样显示出来（换存档后残留的根因之一）。
			# builtVersion 故意不动：卸载进软缓存后必须失效，否则重新进视口会复用旧 buffer
			chunkIns.mesh_instance.visible = false
			return
		# 主线程同步重建并提交 buffer，失败路径与新区块加载完全一致
		_redraw_chunks_frame += 1
		_full_rebuilds_frame += 1
		chunkIns.mesh_instance.drawMap(dirtyBuilds)
		chunkIns.mesh_instance.builtVersion = sw_build_manager.version
		# 之前可能因为区块被清空而隐藏，重建出内容后恢复上屏
		chunkIns.mesh_instance.visible = _visible
	else:
		# Tiling等其他模式：保持原有卸载→重加载逻辑
		chunkIns.status = SwDefine.ChunkStatus.UNLOADING
		if not _pending_tasks.has(0):
			_pending_tasks[0] = {}
		_pending_tasks[0][chunkPos] = false
#TODO _blockSize根据mapDefine来设置



func initDrawMap() -> void:
	_chunkSize=SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE*8
	_blockSize = SwDefine.GRID_SIZE*8
	if not mapData:
		mapData = SwDefine.SWBuildCreator(Vector2i(0,0),mapDefine)
		mapData.rotation = SwDefine.SW_Dir.UP#SwCommon.GetAngleBySWDir(SwDefine.SW_Dir.UP)
		mapDataArray.append(mapData)
	
func initDrawContent() -> void:
	_chunkSize=SwDefine.GRID_SIZE*SwDefine.CHUNK_SIZE
	_blockSize = SwDefine.GRID_SIZE
	pass
	
func setDrawMode(drawMode:SwDefine.GridDrawMode) -> void:
	_drawMode = drawMode
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		initDrawMap()
	else:
		initDrawContent()
	pass
	
func set_visible(enable:bool) -> void:
	if _visible == enable:
		return
	_visible = enable
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.mesh_instance:
			chunkIns.mesh_instance.visible = enable

func is_visible() -> bool:
	return _visible

# 当前已上屏（可见）的区块数量，供性能面板统计
func get_visible_chunk_count() -> int:
	var count:int = 0
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.mesh_instance != null and chunkIns.mesh_instance.visible:
			count += 1
	return count

# 已加载（在 _chunkInstance 中）的区块坐标，供渲染压测/调试统计
func get_loaded_chunk_positions() -> Array[Vector2i]:
	var arr:Array[Vector2i] = []
	for k in _chunkInstance.keys():
		arr.append(k)
	return arr

func _ready() -> void:
	add_to_group("DrawManager")
	if not mapDefine:
		assert(false, "mapDefine未定义")
	swTf = SwDefine.SWTransformData.new()
	setDrawMode(_drawMode)

# 设置异步加载模式
func set_async_loading(enabled: bool) -> void:
	async_loading = enabled

func _process(_delta: float) -> void:
	# 方案 2: 降低查询频率，每 3 帧执行一次
	_frameCounter += 1
	if _frameCounter % _queryFrameInterval != 0:
		return
	# 重置本帧重绘计数，处理完成后快照给性能面板
	_redraw_chunks_frame = 0
	_full_rebuilds_frame = 0
	# 上一帧没处理完的信号补丁继续处理
	_flush_patches(PATCH_BUDGET_USEC)
	process_unload_chunk()
	shouldAddToTree.clear()
	process_load_chunk(0)
	process_load_chunk(1)
	process_load_chunk(2,false)
	for ins in shouldAddToTree:
		add_child(ins)
	_redraw_chunks_last = _redraw_chunks_frame
	pass
	
func process_load_chunk(priority:int,remove:bool = true) -> void:
	if not _pending_tasks.has(priority):
		return
	var tasks: Dictionary = _pending_tasks[priority]
	var count = 0
	var fast_count = 0
	var fast_limit:int = _get_per_frame_limit() * 4
	var keys := tasks.keys()
	var originalMapDataArray = mapDataArray
	# 内容层区块构建已在主线程同步完成：用时间预算兜底，单帧不会因为一次加载
	# 大量区块而长时间卡住（块数上限仍在，两者取先到者）
	var budget_start:int = Time.get_ticks_usec()
	for chunkPos in keys:
		if not _curViewRect.has_point(chunkPos) and (_drawMode != SwDefine.GridDrawMode.ByHold and _drawMode != SwDefine.GridDrawMode.HoldShadow):
			_pending_tasks[priority].erase(chunkPos)
			continue
		var chunkMapDataArray = originalMapDataArray
		if _chunkInstance.has(chunkPos):
			var loadedIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
			if loadedIns.status == SwDefine.ChunkStatus.UNLOADING:
				# 旧区块还没轮到大卸（卸载每帧限流）：任务必须留着，等它退出 _chunkInstance
				# 再按新内容重建；直接删任务会让区块永远停在重建前的旧内容上
				continue
			tasks.erase(chunkPos)
			continue
		# 缓存命中且建筑内容未变：上屏只是恢复可见性，不做任何构建，不受构建限流约束
		var fast_hit:bool = _isCachedContentValid(chunkPos)
		if fast_hit:
			if fast_count >= fast_limit:
				break
			fast_count += 1
		else:
			if count >= _get_per_frame_limit():
				break
			if Time.get_ticks_usec() - budget_start > BUILD_BUDGET_USEC:
				break
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			var chunkBuilds = sw_build_manager.getBuildsByChunkPos(chunkPos)
			if chunkBuilds.size() == 0:
				tasks.erase(chunkPos)
				continue
			chunkMapDataArray = chunkBuilds
		elif _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
			var filteredArray:Array[SWBuildItemDefine] = []
			for build in originalMapDataArray:
				var buildChunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
				if buildChunkPos == chunkPos:
					filteredArray.append(build)
			if filteredArray.size() == 0:
				tasks.erase(chunkPos)
				continue
			chunkMapDataArray = filteredArray
			
		count+=1
		# 优先复用软缓存中保留的区块节点：省去节点创建与整块重建，CPU 缓冲与槽位表也还在
		var chunkIns:SwDefine.SWDrawChunkData = _takeCachedChunk(chunkPos)
		var fromCache:bool = chunkIns != null
		if chunkIns == null:
			chunkIns = SWObjectPool.GetSWChunkDataObject(_drawMode)
		chunkIns.chunk_pos = chunkPos
		if _drawMode == SwDefine.GridDrawMode.ByContent:
			swTf.offset = Vector2(0,0)
		elif _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
			swTf.offset = lastMousePos - _center_offset
		else:
			swTf.offset = Vector2(chunkPos.x,chunkPos.y)
			
		chunkIns.mesh_instance.setMeshSize(_blockSize)
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		chunkIns.mesh_instance.setDrawMode(_drawMode)
		# 来自软缓存且建筑内容自上次构建后没变：MultiMesh 里的 buffer 与实例数仍然有效，直接上屏，
		# 不必重建 320+ 个实例数据，也不必回传 98KB buffer 到渲染服务器
		var reuse_content:bool = fromCache \
				and _drawMode == SwDefine.GridDrawMode.ByContent \
				and chunkIns.mesh_instance.builtVersion == sw_build_manager.version
		if not reuse_content:
			_redraw_chunks_frame += 1
			if _drawMode == SwDefine.GridDrawMode.ByContent and chunkIns.mesh_instance.multimesh:
				chunkIns.mesh_instance.multimesh.visible_instance_count = 0
			chunkIns.mesh_instance.drawMap(chunkMapDataArray)
			chunkIns.mesh_instance.builtVersion = sw_build_manager.version if sw_build_manager else -1
		
		_chunkInstance[chunkPos] = chunkIns
		var mi: SWMultiMeshInstance2D = chunkIns.mesh_instance
		var mi_parent: Node = mi.get_parent()
		if mi_parent != null and mi_parent != self:
			mi_parent.remove_child(mi)
			mi_parent = null
		if mi_parent == null:
			shouldAddToTree.append(mi)
		mi.visible = _visible
		mi.set_process(true)
		chunkIns.status = SwDefine.ChunkStatus.FULLY_LOADED
		tasks.erase(chunkPos)
	mapDataArray = originalMapDataArray
	if tasks.is_empty() and not _draging:
		_pending_tasks.erase(priority)

# 根据当前模式和异步开关计算每帧加载上限
func _get_per_frame_limit() -> int:
	if _drawMode == SwDefine.GridDrawMode.Tiling:
		return max_chunks_per_frame
	elif _drawMode == SwDefine.GridDrawMode.ByContent:
		if async_loading:
			return async_chunks_per_frame
		else:
			return 99999  # 同步模式不限制，一帧加载全部
	return 99999
		

# 只有随相机移动轮换的区块才值得保留节点：内容层（建筑）与地图平铺层都适用
func _use_chunk_cache() -> bool:
	if idle_chunk_cache_size <= 0:
		return false
	return _drawMode == SwDefine.GridDrawMode.ByContent or _drawMode == SwDefine.GridDrawMode.Tiling

# 软缓存中已存在且建筑内容未变的区块：上屏无需重建 buffer
func _isCachedContentValid(chunkPos:Vector2i) -> bool:
	if not _use_chunk_cache() or sw_build_manager == null:
		return false
	if not _idleChunkCache.has(chunkPos):
		return false
	return _idleChunkCache[chunkPos].mesh_instance.builtVersion == sw_build_manager.version

# 把卸载的区块放进软缓存；超过上限时按最久未使用顺序真正销毁
func _cacheChunkNode(chunkPos:Vector2i, chunkIns:SwDefine.SWDrawChunkData) -> void:
	# CPU 侧缓冲与槽位表一起留在缓存里：区块重新进视口后仍能走增量补丁，
	# 否则每次滚屏回来的区块都要在下一次信号变化时整块重建
	if _idleChunkCache.has(chunkPos):
		_evictChunkNode(_idleChunkCache[chunkPos])
	_idleChunkCache[chunkPos] = chunkIns
	_idleChunkOrder.append(chunkPos)
	while _idleChunkOrder.size() > idle_chunk_cache_size:
		var oldest:Vector2i = _idleChunkOrder.pop_front()
		if _idleChunkCache.has(oldest):
			_evictChunkNode(_idleChunkCache[oldest])
			_idleChunkCache.erase(oldest)

# 从软缓存取出区块节点，未命中返回 null
func _takeCachedChunk(chunkPos:Vector2i) -> SwDefine.SWDrawChunkData:
	if not _use_chunk_cache() or not _idleChunkCache.has(chunkPos):
		return null
	var chunkIns:SwDefine.SWDrawChunkData = _idleChunkCache[chunkPos]
	_idleChunkCache.erase(chunkPos)
	_idleChunkOrder.erase(chunkPos)
	chunkIns.status = SwDefine.ChunkStatus.EMPTY
	if chunkIns.mesh_instance.get_parent() == null:
		add_child(chunkIns.mesh_instance)
	return chunkIns

# 真正销毁区块节点：摘出场景树（触发工作线程 join）并归还对象池
func _evictChunkNode(chunkIns:SwDefine.SWDrawChunkData) -> void:
	if chunkIns.mesh_instance.get_parent() != null:
		chunkIns.mesh_instance.get_parent().remove_child(chunkIns.mesh_instance)
	SWObjectPool.DelSWChunkDataObject(chunkIns)

func process_unload_chunk() -> void:
	var forDelPosArr = []
	var unloaded:int = 0
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		if chunkIns.status != SwDefine.ChunkStatus.UNLOADING:
			continue
		# 分帧卸载：每帧只处理固定数量，避免相机快速移动时单帧卸载上百个区块造成长卡顿
		if unloaded >= max_unloads_per_frame:
			break
		unloaded += 1
		chunkIns.status = SwDefine.ChunkStatus.UNVISIBLE
		chunkIns.mesh_instance.set_process(false)
		chunkIns.mesh_instance.visible = false
		forDelPosArr.append(chunkIns.chunk_pos)
		if _use_chunk_cache():
			# 只隐藏并保留节点与 buffer，相机移回来时可直接复用，避免反复 join 工作线程
			_cacheChunkNode(Vector2i(chunkIns.chunk_pos), chunkIns)
		else:
			_evictChunkNode(chunkIns)
	for pos in forDelPosArr:
		_chunkInstance.erase(Vector2i(pos))

func _updateChunkCache(viewRect:Rect2) -> void:
	if _drawMode != SwDefine.GridDrawMode.ByContent:
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

func on_view_rect_changed(viewRect:Rect2 = color_rect.get_rect(),speedVec:Vector2 = Vector2.ZERO) -> void:
	color_rect.position = viewRect.position
	color_rect.size = viewRect.size
	var mmiCount = getNeedCountOfMMI(viewRect)
	var bPos = (viewRect.position/Vector2(_chunkSize))
	var beginChunkPos:Vector2i = floor(bPos)*Vector2(_chunkSize)
	var showInsRect = Rect2(beginChunkPos,Vector2(mmiCount)*Vector2(_chunkSize))
	if _use_chunk_cache():
		# 缓存容量至少覆盖视口区块数的两倍：缩小视角时视口会一次覆盖上百个区块，
		# 容量不够会让缓存刚存进去就被淘汰，来回移动时反复重建
		var need_cache:int = mmiCount.x * mmiCount.y * 2
		if need_cache > idle_chunk_cache_size:
			idle_chunk_cache_size = mini(need_cache, 2048)
	if _drawMode == SwDefine.GridDrawMode.ByHold or _drawMode == SwDefine.GridDrawMode.HoldShadow:
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
				if _drawMode == SwDefine.GridDrawMode.ByContent:
					# 使用缓存，避免重复查询
					if _chunkHasBuildCache.has(chunkPos):
						_pending_tasks[0][chunkPos]=false
				else:
					_pending_tasks[0][chunkPos]=false
	
	if _drawMode == SwDefine.GridDrawMode.Tiling:
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
				_chunkInstance[chunkPos].status = SwDefine.ChunkStatus.UNLOADING
	else:
		var delShowInsRect = Rect2(showInsRect.position,showInsRect.size)
		_curViewRect = delShowInsRect
		# 卸载判定向外扩一圈区块：相机在边界附近移动时不反复卸载/重建
		var keepRect:Rect2 = delShowInsRect
		if unload_margin_chunks > 0:
			keepRect = delShowInsRect.grow(_chunkSize.x * unload_margin_chunks)
		for chunkPos in _chunkInstance.keys():
			var chunkIns:SwDefine.SWDrawChunkData = _chunkInstance[chunkPos]
			if not keepRect.has_point(chunkPos):
				chunkIns.status = SwDefine.ChunkStatus.UNLOADING
			elif chunkIns.status == SwDefine.ChunkStatus.UNLOADING:
				# 挂着全量重建任务的区块不能就地复活：它必须退场后按新内容重建，
				# 否则复活的是重建前的旧 buffer
				if _pending_tasks.has(0) and _pending_tasks[0].has(chunkPos):
					continue
				# 相机又移回保留范围：撤销卸载，避免白白重建一遍
				chunkIns.status = SwDefine.ChunkStatus.FULLY_LOADED
				chunkIns.mesh_instance.visible = _visible
				chunkIns.mesh_instance.set_process(true)
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

func recalcHoldCenter() -> void:
	if not _drawData:
		return
	var centerRect:Rect2=Rect2(0,0,0,0)
	var caled = false
	var mapDataArray = _drawData.mapDatas
	var minPos:Vector2
	var maxPos:Vector2
	for mapData in mapDataArray:
		if not caled:
			caled = true
			minPos = Vector2(mapData.buildAxisPos)
			maxPos = Vector2(mapData.buildAxisPos)+Vector2(_blockSize)
		else:
			minPos.x = min(mapData.buildAxisPos.x,minPos.x)
			minPos.y = min(mapData.buildAxisPos.y,minPos.y)
			maxPos.x = max(mapData.buildAxisPos.x+_blockSize.x,maxPos.x)
			maxPos.y = max(mapData.buildAxisPos.y+_blockSize.y,maxPos.y)
	centerRect.position = minPos
	centerRect.end = maxPos
	_center_offset = centerRect.get_center()
	
func setHoldBuild(drawData:SWDrawData) -> void:
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		chunkIns.status = SwDefine.ChunkStatus.UNLOADING
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
		for mapData:SWBuildItemDefine in mapDataArray:
			mapData.buildState.state = SwDefine.BuildState.HOLDING
			var chunkPos = SwCommon.GetChunkPos(mapData.buildAxisPos)
			_pending_tasks[2][chunkPos] = false
			if not caled:
				caled = true
				minPos = Vector2(mapData.buildAxisPos)
				maxPos = Vector2(mapData.buildAxisPos)+Vector2(_blockSize)
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
var lastMousePos:Vector2 = Vector2(0,0)
func setHoldBuildsPos(mousePos:Vector2) -> void:
	if not _draging:
		return
	lastMousePos = mousePos
	for chunkIns:SwDefine.SWDrawChunkData in _chunkInstance.values():
		swTf.offset = mousePos - _center_offset
		if _drawMode == SwDefine.GridDrawMode.HoldShadow:
			swTf.offset = SwCommon.GetGridPos(swTf.offset+Vector2(_blockSize/2))
		chunkIns.mesh_instance.resetOffsetAndScale(swTf)
		pass
	pass
