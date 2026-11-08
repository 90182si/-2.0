class_name SWObjectPool extends Node

# 启动预热数量：够撑过首屏即可；超过首屏的 chunk 按需 new 并在归还时自然入池，
# 不再启动就 instantiate 上千个 MultiMeshInstance2D 占内存。
const max_chunk_pool = 128
# 按照 GridDrawMode 分池：地图平铺 / 内容 / 手持 / 手持阴影 各自一组对象
static var chunkDataObjectArr:Dictionary = {}
static var delChunkDataObjectArr:Dictionary = {}

static func _get_pool(dict:Dictionary, mode:int) -> Dictionary:
	if not dict.has(mode):
		dict[mode] = {}
	return dict[mode]

static func InitSWChunkDataObject() -> void:
	# 预热地图平铺（Tiling）用的对象池；其他模式按需创建
	var del_pool := _get_pool(delChunkDataObjectArr, SwDefine.GridDrawMode.Tiling)
	#幂等：已预热则跳过，避免反复实例化场景时向 static 池重复追加
	if del_pool.size() > 0:
		return
	for index in range(max_chunk_pool):
		var chunkData:SwDefine.SWDrawChunkData = SwDefine.SWDrawChunkData.new()
		chunkData.init()
		del_pool[chunkData] = true
		
static func GetSWChunkDataObject(drawMode:SwDefine.GridDrawMode) -> SwDefine.SWDrawChunkData:
	var used_pool := _get_pool(chunkDataObjectArr, drawMode)
	var del_pool := _get_pool(delChunkDataObjectArr, drawMode)
	if del_pool.size() == 0:
		var chunkData:SwDefine.SWDrawChunkData = SwDefine.SWDrawChunkData.new()
		chunkData.init()
		used_pool[chunkData] = true
		return chunkData
	else:
		# 直接取第一个 key，避免 keys() 每帧复制整个空闲池（池内有上千个对象）
		var chunkData:SwDefine.SWDrawChunkData = null
		for k in del_pool:
			chunkData = k
			break
		del_pool.erase(chunkData)
		used_pool[chunkData] = true
		# 复用前重置区块与渲染状态，避免残留上一次的 mapData / drawMode 等信息
		chunkData.init()
		return chunkData
	
static func DelSWChunkDataObject(chunkData:SwDefine.SWDrawChunkData) -> void:
	# 根据当前 mesh_instance 使用的绘制模式，归还到对应的池中
	var mode: int = SwDefine.GridDrawMode.Tiling
	if chunkData.mesh_instance:
		mode = chunkData.mesh_instance._drawMode
	var used_pool := _get_pool(chunkDataObjectArr, mode)
	var del_pool := _get_pool(delChunkDataObjectArr, mode)
	used_pool.erase(chunkData)
	# 池不设上限的话，长时间缩放/跳转会让空闲池无限长大：每个区块节点除了节点本身，
	# 还带着一个 MultiMesh 实例缓冲（每块几十 KB），上千个就是几十 MB 纯闲置内存。
	# 超过预热容量就直接销毁，下次需要时重新 new。
	if del_pool.size() >= max_chunk_pool:
		if chunkData.mesh_instance != null:
			chunkData.mesh_instance.queue_free()
		return
	# 归还时释放 CPU 侧的烘焙结果（_cpuBuffer + 槽位表）：进池节点的 builtVersion 被置 -1，
	# 下次取出必定重走 drawMap 整块重建，留着 buffer 只是白占内存。
	if chunkData.mesh_instance != null:
		chunkData.mesh_instance.freeCpuBuffer()
	del_pool[chunkData] = true

static func ClearSWChunkDataObject() -> void:
	chunkDataObjectArr.clear()
	delChunkDataObjectArr.clear()
