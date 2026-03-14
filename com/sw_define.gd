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
	var buildAxisPos:Vector2i
	var buildDefine:SWBuildDefine
	var rotation:int = 0
	func _init(axisPos:Vector2i,buildDef:SWBuildDefine,rot:int = 0) -> void:
		buildAxisPos = axisPos
		buildDefine = buildDef
		rotation = rot

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
			#multi_mesh = mesh_instance.multimesh

#每个区块保存的建筑物信息
class SWChunkBuildData extends Object:
	var builds:Array[SWBuildItemDefine] = []
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
		return true
		
	func delBuild(build:SWBuildItemDefine) -> bool:
		var curChunkRect := Rect2i(chunk_pos,CHUNK_SIZE*GRID_SIZE)
		if not curChunkRect.has_point(build.buildAxisPos):
			return false
		var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/GRID_SIZE
		if builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] == null:
			return false
		var realBuild = builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y]
		realBuild.free()
		builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y] = null
		return true
		
	#func getBuild(axisPos:Vector2i) -> SWBuildItemDefine:
		#var curChunkRect := Rect2i(chunk_pos.x,chunk_pos.y,CHUNK_SIZE,CHUNK_SIZE)
		#if not curChunkRect.has_point(axisPos):
			#return null
		#var inChunkPos:Vector2i = axisPos%CHUNK_SIZE
		#return builds[inChunkPos.x*CHUNK_SIZE+inChunkPos.y]
		
	func getAllBuilds() -> Array[SWBuildItemDefine]:
		var allBuild:Array[SWBuildItemDefine] = []
		for build in builds:
			if build:
				allBuild.append(build)
		return allBuild

#管理所有区块的建筑物信息
class SWBuildManager extends Object:
	var chunkMap:Dictionary[Vector2i,SWChunkBuildData] = {}
	
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
		return curChunk.addBuild(build)
		
	func delBuild(build:SWBuildItemDefine) -> bool:
		if not build:
			return false
		var curChunk = getChunkOrCreate(build.buildAxisPos)
		if not curChunk:
			return false
		return curChunk.delBuild(build)
	
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
		var builds = []
		for axisPos in axisPosArr:
			var chunkPos = (axisPos/CHUNK_SIZE)*CHUNK_SIZE
			if not chunkMap.has(chunkPos):
				continue
			var curChunk = chunkMap[chunkPos]
			var build = curChunk.getBuild(axisPos)
			if build:
				builds.append(build)
		return builds

	func getBuildsByRect(region:Rect2i) -> Array[SWBuildItemDefine]:
		var builds = []
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

	func getBuildsByChunkPos(chunkPos:Vector2i) -> Array[SWBuildItemDefine]:
		var curChunk = getChunkOrCreate(chunkPos)
		if not curChunk:
			return []
		return curChunk.getAllBuilds()

	func getAllBuilds() -> Array[SWBuildItemDefine]:
		var builds = []
		for chunk in chunkMap.values():
			builds.append(chunk.getAllBuilds())
		return builds
