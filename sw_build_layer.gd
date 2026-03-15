class_name SWBuildLayer extends SWLayer

var sw_build_manager:SWDefine.SWBuildManager = null
@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_build_manager = SWDefine.SWBuildManager.new()
	sw_draw_manager.setBuildManager(sw_build_manager)
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.ByContent)
	
	var build:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/按钮.tres") as SWBuildDefine)
	var build2:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/开关.tres") as SWBuildDefine)
	var build3:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/灯泡.tres") as SWBuildDefine)
	var chunkPos = Vector2(-2048,-2048)
	for x in range(0,128*16,128):
		for y in range(0,128*16,128):
			holdIdleBuilds([build],Vector2(x,y)+chunkPos)
			holdIdleBuilds([build2],Vector2(x,y))
			holdIdleBuilds([build3],Vector2(x,y)-chunkPos)

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	pass

func getNotifyChunkPosArr(builds:Array[SWDefine.SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		var chunkPos = SWCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

func holdIdleBuilds(builds:Array[SWDefine.SWBuildItemDefine],pos:Vector2) -> void:
	var gridPos = SWCommon.GetGridPos(pos)
	#print("idle",gridPos)
	var newBuilds:Array[SWDefine.SWBuildItemDefine] = []
	for build in builds:
		var newBuild = SWDefine.SWBuildItemDefine.new(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
		newBuilds.append(newBuild)
	sw_build_manager.addBuilds(newBuilds)
	var notifyChunkPosArr = getNotifyChunkPosArr(newBuilds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass
