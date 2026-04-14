class_name SWBuildLayer extends SWLayer

var sw_build_manager:SWDefine.SWBuildManager = null
@onready var sw_draw_manager: SWDrawManager = $SWDrawManager

func _ready() -> void:
	sw_build_manager = SWDefine.SWBuildManager.new()
	sw_draw_manager.setBuildManager(sw_build_manager)
	sw_draw_manager.setDrawMode(SWDefine.GridDrawMode.ByContent)
	sw_draw_manager.useName = "Content"
	var build:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/按钮.tres") as SWBuildDefine)
	var build2:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/开关.tres") as SWBuildDefine)
	var build3:SWDefine.SWBuildItemDefine = SWDefine.SWBuildItemDefine.new(Vector2i(0,0),load("res://res/灯泡.tres") as SWBuildDefine)
	var chunkPos = Vector2i(-2048,-2048)
	for x in range(0,128*16,128):
		for y in range(0,128*16,128):
			holdIdleBuilds([build],[Vector2i(x,y)+chunkPos])
			holdIdleBuilds([build2],[Vector2i(x,y)])
			holdIdleBuilds([build3],[Vector2i(x,y)-chunkPos])
	
	# 初始化完成后自动运行一次性能测试
	print("建筑创建完成，准备性能测试...")
	call_deferred("_run_initial_performance_test")

func on_view_rect_changed(viewRect:Rect2,speedVec:Vector2) -> void:
	sw_draw_manager.on_view_rect_changed(viewRect,speedVec)
	pass

func getNotifyChunkPosArr(builds:Array[SWDefine.SWBuildItemDefine]) -> Array[Vector2i]:
	var chunkPosMap:Dictionary[Vector2i,bool] = {}
	for build in builds:
		if not build:
			continue
		var chunkPos = SWCommon.GetChunkPos(build.buildAxisPos)
		chunkPosMap[chunkPos] = true
	return chunkPosMap.keys()

func holdIdleBuilds(builds:Array[SWDefine.SWBuildItemDefine],poss:Array[Vector2i]) -> void:
	var successBuilds:Array[SWDefine.SWBuildItemDefine] = []
	for pos in poss:
		var gridPos = SWCommon.GetGridPos(pos)
		#print("idle",gridPos)
		for build in builds:
			var newBuild = SWDefine.SWBuildItemDefine.new(build.buildAxisPos+gridPos,build.buildDefine,build.rotation)
			var ok := sw_build_manager.addBuild(newBuild)
			if ok:
				successBuilds.append(newBuild)
	
	if successBuilds.size() == 0:
		return
	
	var notifyChunkPosArr = getNotifyChunkPosArr(successBuilds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass

func holdRemoveBuilds(poss:Array[Vector2i]) -> void:
	if selectedBuilds.size() != 0:
		var notifyChunkPosArr = getNotifyChunkPosArr(selectedBuilds.keys())
		for build in selectedBuilds:
			if not build:
				continue
			sw_build_manager.setBuildState(build,SWDefine.BuildState.IDLE)
		sw_draw_manager.updataChunks(notifyChunkPosArr)
		selectedBuilds.clear()
		return
	var builds := sw_build_manager.getBuilds(poss)
	for build in builds:
		if selectedBuilds.has(build):
			selectedBuilds.erase(build)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	sw_build_manager.delBuilds(builds)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass

var selectedBuilds:Dictionary[SWDefine.SWBuildItemDefine,bool] = {}
func setSelectedRect(rect:Rect2) -> void:
	var builds := sw_build_manager.getBuildsByRect(rect)
	var notifyChunkPosArr = getNotifyChunkPosArr(builds)
	for build in builds:
		selectedBuilds[build] = true
		sw_build_manager.setBuildState(build,SWDefine.BuildState.SELECTED)
	sw_draw_manager.updataChunks(notifyChunkPosArr)
	pass

# 初始化性能测试
func _run_initial_performance_test():
	await get_tree().create_timer(1.0).timeout  # 等待1秒确保所有建筑创建完成
	print("=== 初始化性能测试 ===")
	var test_region = Rect2i(Vector2i(0, 0), Vector2i(512, 512))
	sw_build_manager.test_getBuildsByRect_performance(test_region)

# 添加性能测试方法 - 按键 'T' 触发
func _input(event):
	if event.is_action_pressed("TEST_PERFORMANCE"):  # 按T键触发性能测试
		print("开始性能测试...")
		# 测试不同大小的区域
		var test_regions = [
			Rect2i(Vector2i(0, 0), Vector2i(512, 512)),    # 小区域
			Rect2i(Vector2i(0, 0), Vector2i(1024, 1024)),  # 中等区域  
			Rect2i(Vector2i(-512, -512), Vector2i(2048, 2048))  # 大区域
		]
		
		for region in test_regions:
			sw_build_manager.test_getBuildsByRect_performance(region)
			# 等待一小段时间避免输出重叠
			await get_tree().create_timer(0.5).timeout
