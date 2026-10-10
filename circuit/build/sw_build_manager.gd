#管理所有区块的建筑物信息
class_name SWBuildManager extends RefCounted

var buildStoreManager:Dictionary[int,SWBuildItemDefine] = {}
var chunkMap:Dictionary[Vector2i,SWChunkBuildData] = {}
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
	var curChunk = getChunkOrCreate(build.buildAxisPos,true)
	if not curChunk:
		return false
	var result = curChunk.addBuild(build)
	if result:
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

# 优化后的方法 - 基于Chunk的查询
func getBuildsByRect(region:Rect2i) -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	
	# 1. 计算矩形区域覆盖的所有 chunk
	var chunk_grid_size = SwDefine.CHUNK_SIZE * SwDefine.GRID_SIZE
	var start_chunk_pos = (Vector2(region.position) / Vector2(chunk_grid_size)).floor()
	var end_chunk_pos = (Vector2(region.end) / Vector2(chunk_grid_size)).ceil()
	
	# 2. 遍历相关 chunk，而不是每个网格点
	for chunk_x in range(start_chunk_pos.x, end_chunk_pos.x):
		for chunk_y in range(start_chunk_pos.y, end_chunk_pos.y):
			var chunk_world_pos = Vector2i(chunk_x, chunk_y) * chunk_grid_size
			var chunk = getChunkOrCreate(chunk_world_pos)
			
			if not chunk:
				continue
			
			# 3. 只检查 chunk 内的建筑
			var chunk_builds = chunk.getAllBuilds()
			for build in chunk_builds:
				if region.has_point(build.buildAxisPos):
					builds.append(build)
	
	return builds

func getBuildCountByChunkPos(chunkPos:Vector2i) -> int:
	if chunkMap.has(chunkPos):
		return 1
	return 0

func getBuildsByChunkPos(chunkPos:Vector2i) -> Array[SWBuildItemDefine]:
	# 方案 3: 缓存优化
	var curChunk = getChunkOrCreate(chunkPos)
	if not curChunk:
		return []
	var builds = curChunk.getAllBuilds()
	return builds

func getAllBuilds() -> Array[SWBuildItemDefine]:
	var builds:Array[SWBuildItemDefine] = []
	for chunk in chunkMap.values():
		for build in chunk.getAllBuilds():
			builds.append(build)
	return builds

func clearAllBuilds() -> void:
	chunkMap.clear()
	cacheValid = false
	build_changed.emit()
