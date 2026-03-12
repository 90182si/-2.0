class_name SWObjectPool extends Node

const max_chunk_pool = 1400
static var chunkDataObjectArr:Dictionary[SWDefine.SWDrawChunkData,bool] = {}
static var delChunkDataObjectArr:Dictionary[SWDefine.SWDrawChunkData,bool] = {}

static func InitSWChunkDataObject() -> void:
	for index in range(max_chunk_pool):
		var chunkData:SWDefine.SWDrawChunkData = SWDefine.SWDrawChunkData.new()
		chunkData.init()
		delChunkDataObjectArr[chunkData]=true
		
static func GetSWChunkDataObject() -> SWDefine.SWDrawChunkData:
	if delChunkDataObjectArr.size() == 0:
		var chunkData:SWDefine.SWDrawChunkData = SWDefine.SWDrawChunkData.new()
		chunkData.init()
		chunkDataObjectArr[chunkData]=true
		return chunkData
	else:
		var chunkData = delChunkDataObjectArr.keys().front()
		delChunkDataObjectArr.erase(chunkData)
		chunkDataObjectArr[chunkData]=true
		return chunkData
	
static func DelSWChunkDataObject(chunkData:SWDefine.SWDrawChunkData) -> void:
	chunkDataObjectArr.erase(chunkData)
	delChunkDataObjectArr[chunkData]=true

static func ClearSWChunkDataObject() -> void:
	chunkDataObjectArr.clear()
	delChunkDataObjectArr.clear()
