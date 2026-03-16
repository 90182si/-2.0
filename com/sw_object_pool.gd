class_name SWObjectPool extends Node

const max_chunk_pool = 1400
# 按照 GridDrawMode 分池：地图平铺 / 内容 / 手持 / 手持阴影 各自一组对象
static var chunkDataObjectArr:Dictionary = {}
static var delChunkDataObjectArr:Dictionary = {}

static func _get_pool(dict:Dictionary, mode:int) -> Dictionary:
	if not dict.has(mode):
		dict[mode] = {}
	return dict[mode]

static func InitSWChunkDataObject() -> void:
	# 预热地图平铺（Tiling）用的对象池；其他模式按需创建
	var del_pool := _get_pool(delChunkDataObjectArr, SWDefine.GridDrawMode.Tiling)
	for index in range(max_chunk_pool):
		var chunkData:SWDefine.SWDrawChunkData = SWDefine.SWDrawChunkData.new()
		chunkData.init()
		del_pool[chunkData] = true
		
static func GetSWChunkDataObject(drawMode:SWDefine.GridDrawMode) -> SWDefine.SWDrawChunkData:
	var used_pool := _get_pool(chunkDataObjectArr, drawMode)
	var del_pool := _get_pool(delChunkDataObjectArr, drawMode)
	if del_pool.size() == 0:
		var chunkData:SWDefine.SWDrawChunkData = SWDefine.SWDrawChunkData.new()
		chunkData.init()
		used_pool[chunkData] = true
		return chunkData
	else:
		var chunkData:SWDefine.SWDrawChunkData = del_pool.keys().front()
		del_pool.erase(chunkData)
		used_pool[chunkData] = true
		# 复用前重置区块与渲染状态，避免残留上一次的 mapData / drawMode 等信息
		chunkData.init()
		return chunkData
	
static func DelSWChunkDataObject(chunkData:SWDefine.SWDrawChunkData) -> void:
	# 根据当前 mesh_instance 使用的绘制模式，归还到对应的池中
	var mode: int = SWDefine.GridDrawMode.Tiling
	if chunkData.mesh_instance:
		mode = chunkData.mesh_instance._drawMode
	var used_pool := _get_pool(chunkDataObjectArr, mode)
	var del_pool := _get_pool(delChunkDataObjectArr, mode)
	used_pool.erase(chunkData)
	del_pool[chunkData] = true

static func ClearSWChunkDataObject() -> void:
	chunkDataObjectArr.clear()
	delChunkDataObjectArr.clear()
