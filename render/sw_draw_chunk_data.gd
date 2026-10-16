#每个区块保存的建筑物信息
class_name SWChunkBuildData extends RefCounted
var builds:Array[SWBuildItemDefine] = []
var notNullBuilds:Array[SWBuildItemDefine] = []
# 影子登记：锚点不在本 chunk 但 footprint 覆盖到本 chunk 的大建筑引用
var shadowBuilds:Array[SWBuildItemDefine] = []
var chunk_key:String = ""
var chunk_pos:Vector2i

func _init(chunkPos:Vector2i) -> void:
	chunk_pos = chunkPos
	chunk_key = "{}|{}".format([chunkPos.x,chunkPos.y])
	for index in range(SwDefine.CHUNK_SIZE*SwDefine.CHUNK_SIZE):
		builds.append(null)

func addBuild(build:SWBuildItemDefine) -> bool:
	var curChunkRect := Rect2i(chunk_pos,SwDefine.CHUNK_SIZE*SwDefine.GRID_SIZE)
	if not curChunkRect.has_point(build.buildAxisPos):
		return false
	var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/SwDefine.GRID_SIZE
	if builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y] != null:
		return false
	builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y] = build
	notNullBuilds.append(build)
	return true
	
func getBuild(axisPos:Vector2i) -> SWBuildItemDefine:
	var curChunkRect := Rect2i(chunk_pos,SwDefine.CHUNK_SIZE*SwDefine.GRID_SIZE)
	if not curChunkRect.has_point(axisPos):
		return null
	var inChunkPos:Vector2i = (axisPos-curChunkRect.position)/SwDefine.GRID_SIZE
	return builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y]
	
func delBuild(build:SWBuildItemDefine) -> bool:
	var curChunkRect := Rect2i(chunk_pos,SwDefine.CHUNK_SIZE*SwDefine.GRID_SIZE)
	if not curChunkRect.has_point(build.buildAxisPos):
		return false
	var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/SwDefine.GRID_SIZE
	if builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y] == null:
		return false
	var realBuild = builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y]
	notNullBuilds.erase(realBuild)
	#realBuild.free()
	builds[inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y] = null
	return true
	
func getAllBuilds() -> Array[SWBuildItemDefine]:
	return notNullBuilds
