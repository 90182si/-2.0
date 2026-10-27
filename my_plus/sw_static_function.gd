extends Node

#获取rect范围内的chunkPos
static func GetChunkPosByRect(view_rect:Rect2,chunk_size:int) -> Array[Vector2i]:
	var bPos:Vector2 = (view_rect.position/chunk_size)
	var beginChunkPos:Vector2i = floor(bPos)*chunk_size
	var ePos:Vector2 = (view_rect.end/chunk_size)
	var endChunkPos:Vector2i = ceil(ePos)*chunk_size
	var chunk_pos_arr:Array[Vector2i] = []
	for chunk_x in range(bPos.x,ePos.x+chunk_size,chunk_size):
		for chunk_y in range(bPos.y,ePos.y+chunk_size,chunk_size):
			chunk_pos_arr.append(Vector2i(chunk_x,chunk_y))
	return chunk_pos_arr
