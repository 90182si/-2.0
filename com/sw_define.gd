class_name SWDefine extends Node

const CHUNK_SIZE = 16
const VIEW_MAX_LEVEL = 4
const VIEW_MIN_LEVEL = -30-15
const VIEW_NEXT_LEVEL = -14
const GRID_SIZE = Vector2i(128,128)

enum GridDrawMode {
	Tiling,   #平铺显示
	ByContent, #根据数据内容显示
	ByHold,   #显示手持
	HoldShadow#手持阴影
}

enum SW_Dir {
	UP,
	RIGHT,
	DOWN,
	LEFT
}

enum BuildOpr{
	Place,
	Erase,
	BeginSelect,
	EndSelect,
	Selecting,
	Rotate
}

# 加载层级优先级
enum ChunkPriority {
	HIGH = 0,  # 即时层（0-2）
	MEDIUM = 1,  # 缓冲层（3-5）
	LOW = 2     # 边缘层（6-10）
}

# 区块状态枚举
enum ChunkStatus {
	EMPTY,
	TERRAIN_GENERATED,
	FULLY_LOADED,#可见
	UNVISIBLE,#不可见
	UNLOADING,
	UNLOADED
}

#建筑物状态
enum BuildState{
	IDLE,
	SELECTED
}

#视口偏移与缩放
class SWTransformData extends Object:
	var offset:Vector2 = Vector2(0,0)
	var scale:Vector2 = Vector2(1.0,1.0)
	
#地图网格图集定义
#class SWDrawGridDefine extends Object:
	#var gridPos:Vector2i = Vector2i(0,0)#需要绘制在网格的哪个位置
	#var atlasRegion:Vector4i = Vector4i(0,0,0,0)#图集位置
	#var angle:SW_Dir = SW_Dir.UP#方向

#建筑物定义
class SWBuildItemDefine extends Object:
	var innerData:SWBuildInnerData = null
	var id:int
	var buildAxisPos:Vector2i
	var buildDefine:SWBuildDefine
	var rotation:int = 0
	func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
		innerData = SWBuildInnerData.new()
		buildAxisPos = axisPos
		buildDefine = buildDef
		rotation = rot
		id = SWCommon.GenNextBuildId()

# 区块数据结构（存储核心信息，不直接存储渲染节点）
class SWDrawChunkData extends Object:
	var chunk_pos: Vector2  # 区块坐标（cx, cz）
	var world_pos: Vector2  # 世界坐标（x, y）
	var status: SWDefine.ChunkStatus = SWDefine.ChunkStatus.EMPTY
	var priority: SWDefine.ChunkPriority = SWDefine.ChunkPriority.LOW
	var mesh_instance: SWMultiMeshInstance2D = null  # 批量渲染节点
	#var multi_mesh: MultiMesh = null  # 批量网格数据
	func init() -> void:
		chunk_pos = Vector2.ZERO
		world_pos = Vector2.ZERO
		status = SWDefine.ChunkStatus.EMPTY
		priority = SWDefine.ChunkPriority.LOW
		if not mesh_instance:
			mesh_instance = preload("res://sw_multi_mesh_instance_2d.tscn").instantiate() 
			mesh_instance.chunkPtr = self
			mesh_instance._hadDraw = false
		mesh_instance.reUse()
			#multi_mesh = mesh_instance.multimesh

class SWBuildStateStrategy extends Object:
	var innerData:SWBuildInnerData = null
	func _init() -> void:
		pass
	func stateChanged(innerData:SWBuildInnerData,state:SWDefine.BuildState) -> void:
		innerData.mask_color = Color(1,1,1,1)
		
class SWBuildStateSelected extends SWBuildStateStrategy:
	func stateChanged(innerData:SWBuildInnerData,state:SWDefine.BuildState) -> void:
		if state == SWDefine.BuildState.IDLE:
			innerData.mask_color = Color(1,1,1,1)
		elif state == SWDefine.BuildState.SELECTED:
			innerData.mask_color = Color(0.157, 0.557, 0.906, 0.788)

#建筑物内部数据
class SWBuildInnerData extends Resource:
	var mask_color:Color = Color(1.0, 1.0, 1.0, 1.0)
	var buildStateStrategy:SWBuildStateStrategy = null
	var state:SWDefine.BuildState = SWDefine.BuildState.IDLE:
		set(s):
			state = s
			if buildStateStrategy:
				buildStateStrategy.stateChanged(self,s)
	
	func _init() -> void:
		buildStateStrategy = SWBuildStateSelected.new()
	pass

#每个区块保存的建筑物信息
class SWChunkBuildData extends Object:
	var builds:Array[SWBuildItemDefine] = []
	var notNullBuilds:Array[SWBuildItemDefine] = []
	var chunk_key:String = ""
	var chunk_pos:Vector2i
	
	func _init(chunkPos:Vector2i) -> void:
		chunk_pos = chunkPos
		chunk_key = "{}|{}".format([chunkPos.x,chunkPos.y])
		for index in range(CHUNK_SIZE*CHUNK_SIZE):
			builds.append(null)
	
	func addBuild(build:SWBuildItemDefine) -> bool:
		var curChunkRect := Rect2i(chunk_pos,CHUNK_SIZE*GRID_SIZE)
		if not curChunkRect.has_point(build.buildAxisPos):
			return false
		var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/GRID_SIZE
		if builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] != null:
			return false
		builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] = build
		notNullBuilds.append(build)
		return true
		
	func getBuild(axisPos:Vector2i) -> SWBuildItemDefine:
		var curChunkRect := Rect2i(chunk_pos,CHUNK_SIZE*GRID_SIZE)
		if not curChunkRect.has_point(axisPos):
			return null
		var inChunkPos:Vector2i = (axisPos-curChunkRect.position)/GRID_SIZE
		return builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y]
		
	func delBuild(build:SWBuildItemDefine) -> bool:
		var curChunkRect := Rect2i(chunk_pos,CHUNK_SIZE*GRID_SIZE)
		if not curChunkRect.has_point(build.buildAxisPos):
			return false
		var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/GRID_SIZE
		if builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] == null:
			return false
		var realBuild = builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y]
		notNullBuilds.erase(realBuild)
		realBuild.free()
		builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] = null
		return true
		
	func getAllBuilds() -> Array[SWBuildItemDefine]:
		return notNullBuilds
		#var allBuild:Array[SWBuildItemDefine] = []
		#for build in builds:
			#if build:
				#allBuild.append(build)
		#return allBuild

#管理所有区块的建筑物信息
class SWBuildManager extends Object:
	#var buildStoreManager:Dictionary[int,SWBuildInnerData] = {}
	var chunkMap:Dictionary[Vector2i,SWChunkBuildData] = {}
	# 方案 3: 缓存 chunkPos→builds 映射
	var cacheValid:bool = false
	# 建筑变化信号
	signal build_changed()
	
	########
	func setBuildState(build:SWBuildItemDefine,state:SWDefine.BuildState) -> void:
		build.innerData.state = state
		pass
	########
	
	func getChunkOrCreate(axisPos:Vector2i,create:bool = false) -> SWChunkBuildData:
		var chunkPos1 = (Vector2(axisPos)/Vector2(CHUNK_SIZE*GRID_SIZE)).floor()
		var chunkPos = Vector2i(chunkPos1*CHUNK_SIZE*Vector2(GRID_SIZE))
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
			build_changed.emit()
		return result
		
	func delBuild(build:SWBuildItemDefine) -> bool:
		if not build:
			return false
		var curChunk = getChunkOrCreate(build.buildAxisPos)
		if not curChunk:
			return false
		var result = curChunk.delBuild(build)
		if result:
			build_changed.emit()
		return result
	
	func addBuilds(builds:Array[SWBuildItemDefine]) -> bool:
		var success = true
		for build in builds:
			var ok = addBuild(build)
			if ok == false:
				success = false
				assert("在{},{}添加{}失败".format([build.buildAxisPos.x,build.buildAxisPos.y,build.buildDefine.buildName]))
		return success
		
	func delBuilds(builds:Array[SWBuildItemDefine]) -> bool:
		var success = true
		for build in builds:
			var assertStr = "在{},{}删除{}失败".format([build.buildAxisPos.x,build.buildAxisPos.y,build.buildDefine.buildName])
			var ok = delBuild(build)
			if ok == false:
				success = false
				assert(assertStr)
		return success
		
	func getBuild(axisPos:Vector2i) -> SWBuildItemDefine:
		var curChunk = getChunkOrCreate(axisPos)
		if not curChunk:
			return null
		return curChunk.getBuild(axisPos)
		
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
		var chunk_grid_size = CHUNK_SIZE * GRID_SIZE
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
		var builds = []
		for chunk in chunkMap.values():
			builds.append(chunk.getAllBuilds())
		return builds

	# 性能测试方法 - 对比原始方法和优化方法
	func test_getBuildsByRect_performance(region:Rect2i = Rect2i(Vector2i(0, 0), Vector2i(1024, 1024))) -> void:
		print("=== 性能测试开始 ===")
		print("测试区域: ", region, " 大小: ", region.size)
		
		# 测试原方法
		var start_time = Time.get_ticks_msec()
		var old_results = getBuildsByRect_old(region)
		var old_time = Time.get_ticks_msec() - start_time
		
		# 测试新方法
		start_time = Time.get_ticks_msec()
		var new_results = getBuildsByRect(region)
		var new_time = Time.get_ticks_msec() - start_time
		
		# 验证结果一致性
		var results_match = old_results.size() == new_results.size()
		if results_match and old_results.size() > 0:
			# 简单验证：检查前几个结果是否相同
			for i in range(min(5, old_results.size())):
				if old_results[i] != new_results[i]:
					results_match = false
					break
		
		print("原始方法耗时: ", old_time, "ms, 结果数: ", old_results.size())
		print("优化方法耗时: ", new_time, "ms, 结果数: ", new_results.size())
		print("性能提升: ", float(old_time) / float(new_time), "倍")
		print("结果一致性: ", "✓ 通过" if results_match else "✗ 失败")
		print("=== 性能测试结束 ===")
		print()
