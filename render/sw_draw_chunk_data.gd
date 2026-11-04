#每个区块保存的建筑物信息
class_name SWChunkBuildData extends RefCounted
var builds:Array[SWBuildItemDefine] = []
var notNullBuilds:Array[SWBuildItemDefine] = []
var dirtyBuilds:Array[SWBuildItemDefine] = []
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

# 批量删除：先清槽位，再一次性压缩 notNullBuilds。
# delBuild 里的 notNullBuilds.erase 是 O(区块内建筑数) 的搬移，成批删就退化成
# O(区块内建筑数 × 删除数)；一次删上万个元件时这里是百毫秒量级的浪费。
# 返回真正被删掉的建筑（槽位对不上的、已不在本区块的不算）。
func removeBuilds(toRemove:Array) -> Array[SWBuildItemDefine]:
	var gone:Array[SWBuildItemDefine] = []
	if toRemove.is_empty():
		return gone
	var curChunkRect := Rect2i(chunk_pos,SwDefine.CHUNK_SIZE*SwDefine.GRID_SIZE)
	var goneMap:Dictionary[SWBuildItemDefine,bool] = {}
	for build:SWBuildItemDefine in toRemove:
		if build == null:
			continue
		if not curChunkRect.has_point(build.buildAxisPos):
			continue
		var inChunkPos:Vector2i = (build.buildAxisPos-curChunkRect.position)/SwDefine.GRID_SIZE
		var idx:int = inChunkPos.x*SwDefine.CHUNK_SIZE+inChunkPos.y
		if builds[idx] != build:
			continue
		builds[idx] = null
		goneMap[build] = true
		gone.append(build)
	if goneMap.is_empty():
		return gone
	# 一趟压缩：O(区块内建筑数)，与删了几个无关
	var kept:Array[SWBuildItemDefine] = []
	kept.resize(notNullBuilds.size())
	var w:int = 0
	for b:SWBuildItemDefine in notNullBuilds:
		if goneMap.has(b):
			continue
		kept[w] = b
		w += 1
	kept.resize(w)
	notNullBuilds = kept
	return gone
	
func getAllBuilds() -> Array[SWBuildItemDefine]:
	return notNullBuilds

func setDirty(build:SWBuildItemDefine,dirty:bool) -> void:
	build.dirty = dirty
	if dirty:
		dirtyBuilds.append(build)
	else:
		dirtyBuilds.erase(build)

func getAllDirtyBuilds() -> Array[SWBuildItemDefine]:
	return dirtyBuilds
	
func setChunkDirtyClear() -> void:
	dirtyBuilds.clear()
