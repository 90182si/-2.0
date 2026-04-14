class_name SWCommon extends Node

static var id = 0
static func GenNextBuildId() -> int:
	id += 1
	return id
	
static func GetAngleBySWDir(dir:SWDefine.SW_Dir) -> int:
	match dir:
		SWDefine.SW_Dir.UP:
			return 0
		SWDefine.SW_Dir.DOWN:
			return 180
		SWDefine.SW_Dir.RIGHT:
			return 270
		SWDefine.SW_Dir.LEFT:
			return 90
	return 0

static func GetGlobalPosByViewPos(viewPos: Vector2, viewport: Viewport) -> Vector2:
	var canvas_transform := viewport.get_canvas_transform()
	return canvas_transform.affine_inverse() * viewPos

#获取某个位置对应网格的起始坐标
static func GetGridPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/Vector2(SWDefine.GRID_SIZE)
	var pos = pos1.floor()
	var gridPos:Vector2i = Vector2i(pos)*SWDefine.GRID_SIZE
	return gridPos

static func GetChunkPos(worldPos:Vector2i) -> Vector2i:
	var pos1 = Vector2(worldPos)/(Vector2(SWDefine.GRID_SIZE)*SWDefine.CHUNK_SIZE)
	var pos = pos1.floor()
	var chunkPos:Vector2i = Vector2i(pos)*SWDefine.GRID_SIZE*SWDefine.CHUNK_SIZE
	return chunkPos

#以rotCenter为旋转中心，对srcPos旋转deg度
static func RotationPos(srcPos:Vector2,deg:float,rotCenter:Vector2) -> Vector2:
	if deg == 0.0:
		return srcPos
	return (srcPos - rotCenter).rotated(deg_to_rad(deg)) + rotCenter
