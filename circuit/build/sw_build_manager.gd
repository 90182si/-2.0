#管理所有区块的建筑物信息
class_name SWBuildManager extends RefCounted

var buildStoreManager:Dictionary[int,SWBuildItemDefine] = {}
var chunkMap:Dictionary[Vector2i,SWChunkBuildData] = {}
# occupancy 占位表：Vector2i(axisPos) → int(build.id)，用于 m×n 多格建筑占位管理
var occupancy: Dictionary = {}
# 方案 3: 缓存 chunkPos→builds 映射
var cacheValid:bool = false
# 建筑变化信号
signal build_changed()

########
func setBuildState(build:SWBuildItemDefine,state:SwDefine.BuildState) -> void:
	build.buildState.state = state
	pass

func setBuildsState(builds:Array[SWBuildItemDefine],state:SwDefine.BuildState) -> void:
	for build in builds:
		build.buildState.state = state
	pass
########

func getChunkOrCreate(axisPos:Vector2i,create:bool = false) -> SWChunkBuildData:
	var chunkPos1 = (Vector2(axisPos)/Vector2(SwDefine.CHUNK_SIZE*SwDefine.GRID_SIZE)).floor()
	var chunkPos = Vector2i(chunkPos1*SwDefine.CHUNK_SIZE*Vector2(SwDefine.GRID_SIZE))
	if not chunkMap.has(chunkPos):
		if create:
			chunkMap[chunkPos] = SWChunkBuildData.new(chunkPos)
		else:
			return null
	return chunkMap[chunkPos]

func addBuild(build:SWBuildItemDefine) -> bool:
	if not build:
		return false
	# 1. 校验 occupancy：所有覆盖格必须空闲（0 或不存在）
	var cells := build.getCoveredCells()
	for cell in cells:
		var occId: int = occupancy.get(cell, 0)
		if occId != 0:
			return false  # 任一格冲突，整体失败（原子性）
	# 2. 写入 occupancy
	for cell in cells:
		occupancy[cell] = build.id
	# 3. 原 chunk 登记逻辑（仅登记锚点格）
	var curChunk = getChunkOrCreate(build.buildAxisPos,true)
	if not curChunk:
		return false
	var result = curChunk.addBuild(build)
	if result:
		# 4. 影子登记：footprint 覆盖的其他 chunk 记录影子引用
		var anchorChunkPos := SwCommon.GetChunkPos(build.buildAxisPos)
		var shadowChunks: Dictionary = {}  # chunkPos → true，去重
		for cell in cells:
			var cp := SwCommon.GetChunkPos(cell)
			if cp != anchorChunkPos:
				shadowChunks[cp] = true
		for cp in shadowChunks.keys():
			var shadowChunk = getChunkOrCreate(cp, true)
			if shadowChunk:
				shadowChunk.shadowBuilds.append(build)
		buildStoreManager[build.id] = build
		build.on_idled(self)
		build_changed.emit()
	return result
	
#func delBuild(build:SWBuildItemDefine) -> bool:
	#if not build:
		#return false
	#var curChunk = getChunkOrCreate(build.buildAxisPos)
	#if not curChunk:
		#return false
	#var result = curChunk.delBuild(build)
	#if result:
		#buildStoreManager.erase(build.id)
		#build.on_deleted(self)
		#build_changed.emit()
	#return result

func addBuilds(builds:Array[SWBuildItemDefine]) -> bool:
	var success = true
	for build in builds:
		var ok = addBuild(build)
		if ok == false:
			success = false
			assert("在{},{}添加{}失败".format([build.buildAxisPos.x,build.buildAxisPos.y,build.buildDefine.buildName]))
		else:
			buildStoreManager[build.id] = build
	return success
	
func delBuilds(builds:Array[SWBuildItemDefine]) -> bool:
	if builds.is_empty():
		return true
	var success = true
	var chunkBuildMap:Dictionary[Vector2i, Array] = {}
	for build in builds:
		if not build:
			success = false
			continue
		var chunkPos = SwCommon.GetChunkPos(build.buildAxisPos)
		if not chunkBuildMap.has(chunkPos):
			chunkBuildMap[chunkPos] = []
		chunkBuildMap[chunkPos].append(build)
	var anyDeleted = false
	for chunkPos in chunkBuildMap.keys():
		var curChunk = chunkMap.get(chunkPos)
		if not curChunk:
			for build in chunkBuildMap[chunkPos]:
				success = false
				assert("在{},{}删除{}失败".format([build.buildAxisPos.x, build.buildAxisPos.y, build.buildDefine.buildName]))
			continue
		for build in chunkBuildMap[chunkPos]:
			var ok = curChunk.delBuild(build)
			if ok:
				# 按 footprint 逐格清 occupancy，仅当 occupancy[cell] == build.id 才清（防误删）
				for cell in build.getCoveredCells():
					if occupancy.get(cell, 0) == build.id:
						occupancy.erase(cell)
				# 清影子登记：footprint 覆盖的非锚点 chunk 移除影子引用
				var anchorChunkPos := SwCommon.GetChunkPos(build.buildAxisPos)
				var shadowChunks: Dictionary = {}
				for cell in build.getCoveredCells():
					var cp := SwCommon.GetChunkPos(cell)
					if cp != anchorChunkPos:
						shadowChunks[cp] = true
				for cp in shadowChunks.keys():
					var shadowChunk = chunkMap.get(cp)
					if shadowChunk:
						shadowChunk.shadowBuilds.erase(build)
				build.on_deleted(self)
				anyDeleted = true
			else:
				success = false
				assert("在{},{}删除{}失败".format([build.buildAxisPos.x, build.buildAxisPos.y, build.buildDefine.buildName]))
	if anyDeleted:
		cacheValid = false
		build_changed.emit()
	return success
	
func getBuild(axisPos:Vector2i) -> SWBuildItemDefine:
	# 优先查 occupancy（O(1) 命中 m×n 建筑的任意覆盖格）
	var occId: int = occupancy.get(axisPos, 0)
	if occId != 0:
		var build := getBuildById(occId)
		if build and not build.bIsToBeRemoved():
			return build
	# 回退：原单格逻辑（兼容 1×1 建筑或 occupancy 未登记的情况）
	var curChunk = getChunkOrCreate(axisPos)
	if not curChunk:
		return null
	return curChunk.getBuild(axisPos)
	
func getBuildById(id:int) -> SWBuildItemDefine:
	if buildStoreManager.has(id):
		return buildStoreManager[id]
	return null

func getBuilds(axisPosArr:Array[Vector2i]) -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	for axisPos in axisPosArr:
		var build = getBuild(axisPos)
		if build:
			builds.append(build)
	return builds

# 原始方法 - 保留用于对比
func getBuildsByRect_old(region:Rect2i) -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	for x in range(region.position.x,region.end.x,1):
		for y in range(region.position.y,region.end.y,1):
			var pos = Vector2i(x,y)
			var curChunk = getChunkOrCreate(pos)
			if not curChunk:
				continue
			var build = curChunk.getBuild(pos)
			if build:
				builds.append(build)
		pass
	return builds

# 优化后的方法 - 基于Chunk的查询 + occupancy footprint 相交判定
func getBuildsByRect(region:Rect2i) -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	var seen: Dictionary = {}  # build.id → true，去重防跨 chunk 重复收集
	
	# 1. 计算矩形区域覆盖的所有 chunk
	var chunk_grid_size = SwDefine.CHUNK_SIZE * SwDefine.GRID_SIZE
	var start_chunk_pos = (Vector2(region.position) / Vector2(chunk_grid_size)).floor()
	var end_chunk_pos = (Vector2(region.end) / Vector2(chunk_grid_size)).ceil()
	
	# 2. 遍历相关 chunk
	for chunk_x in range(start_chunk_pos.x, end_chunk_pos.x):
		for chunk_y in range(start_chunk_pos.y, end_chunk_pos.y):
			var chunk_world_pos = Vector2i(chunk_x, chunk_y) * chunk_grid_size
			var chunk = getChunkOrCreate(chunk_world_pos)
			
			if not chunk:
				continue
			
			# 3. 检查 chunk 内的建筑：footprint 矩形与 region 相交即命中
			var chunk_builds = chunk.getAllBuilds()
			for build in chunk_builds:
				if seen.has(build.id):
					continue
				var fp := build.getFootprint()
				var buildRect := Rect2i(build.buildAxisPos, fp * SwDefine.GRID_SIZE)
				if buildRect.intersects(region):
					builds.append(build)
					seen[build.id] = true
	
	return builds

func getBuildCountByChunkPos(chunkPos:Vector2i) -> int:
	if chunkMap.has(chunkPos):
		return 1
	return 0

## 获取 chunk 内用于渲染的建筑（仅锚点在此 chunk 的）
func getRenderBuildsByChunkPos(chunkPos:Vector2i) -> Array[SWBuildItemDefine]:
	var chunk = getChunkOrCreate(chunkPos)
	if not chunk:
		return []
	#var retArr:Array[SWBuildItemDefine] = []
	#for build:SWBuildItemDefine in chunk.notNullBuilds:
		#if build.getRenderableCompoent().isRenderPartsDirty():
			#retArr.append(build)
	#return retArr
	return chunk.notNullBuilds

## 获取 chunk 内全部建筑（含影子，用于查询/通知）
func getBuildsByChunkPos(chunkPos:Vector2i) -> Array[SWBuildItemDefine]:
	var chunk = getChunkOrCreate(chunkPos)
	if not chunk:
		return []
	var result: Array[SWBuildItemDefine] = []
	result.append_array(chunk.getAllBuilds())
	result.append_array(chunk.shadowBuilds)
	return result

func getAllBuilds() -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	for chunk in chunkMap.values():
		for build in chunk.getAllBuilds():
			builds.append(build)
	return builds

func clearAllBuilds() -> void:
	chunkMap.clear()
	occupancy.clear()
	#同步清空 id 索引表，避免加载新存档后 getBuildById 返回上一次会话的孤立建筑（尤其隧道 pairId 按 id 查找）
	buildStoreManager.clear()
	cacheValid = false
	build_changed.emit()
