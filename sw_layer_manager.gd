class_name SWLayerManager extends Node

var layers:Array[SWLayer] = []
var hudLayer:SWHudLayer = null
var holdLayer:SWHoldLayer = null
var buildLayer:SWBuildLayer = null

func _ready() -> void:
	var _layers = get_tree().get_nodes_in_group("SWLayer")
	for layer in _layers:
		if layer is SWLayer:
			layers.append(layer)
		if layer is SWHudLayer:
			hudLayer = layer
			hudLayer.selTool.connect(hudLayerSelectedTool)
			hudLayer.save_requested.connect(_on_save_requested)
			hudLayer.load_requested.connect(_on_load_requested)
		if layer is SWHoldLayer:
			holdLayer = layer
		if layer is SWBuildLayer:
			buildLayer = layer
	if buildLayer and holdLayer:
		buildLayer.holdLayerRef = holdLayer
		holdLayer.holdIdleBuilds.connect(buildLayer.holdIdleBuilds)
		holdLayer.holdRemoveBuilds.connect(buildLayer.holdRemoveBuilds)
		holdLayer.selectBuildsByRect.connect(func(rect):
			print("选中",rect)
			buildLayer.setSelectedRect(rect))
		holdLayer.deselectBuildsByRect.connect(func(rect):
			print("取消选中",rect)
			buildLayer.clearSelectedByRect(rect))
		buildLayer.cut_builds.connect(buildLayer._do_cut)
		buildLayer.copy_builds.connect(buildLayer._do_copy)
		holdLayer.drag_started.connect(buildLayer._on_drag_started)
		holdLayer.drag_ended.connect(buildLayer._on_drag_ended)
		
	var build:SWBuildDefine = load("res://res/非门.tres") as SWBuildDefine
	var build2:SWBuildDefine = load("res://res/开关.tres") as SWBuildDefine
	var build3:SWBuildDefine = load("res://res/电线A.tres") as SWBuildDefine
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),build2)
	drawData.addOneDrawBuildDefine(Vector2i(128,0),build2)
	drawData.addOneDrawBuildDefine(Vector2i(0,-128),build)
	drawData.addOneDrawBuildDefine(Vector2i(128,-128),build)
	drawData.addOneDrawBuildDefine(Vector2i(0,-256),build3)
	drawData.addOneDrawBuildDefine(Vector2i(128,-256),build3)
	
	holdLayer.on_sel_tool_draw_data(drawData)
			
func hudLayerSelectedTool(buildDefine:SWBuildDefine) -> void:
	var drawData:SWDrawData = SWDrawData.new()
	drawData.addOneDrawBuildDefine(Vector2i(0,0),buildDefine)
	holdLayer.on_sel_tool_draw_data(drawData)

func _on_save_requested() -> void:
	var dialog = preload("res://ui/sw_save_dialog.tscn").instantiate()
	dialog.save_confirmed.connect(func (name: String):
		print("[Save] 开始保存: ", name)
		if buildLayer == null:
			push_error("[Save] buildLayer 为 null!")
			return
		# 先隐藏对话框再截图
		dialog.visible = false
		await get_tree().process_frame
		var builds = buildLayer.sw_build_manager.getAllBuilds()
		print("[Save] 获取到建筑物: ", builds.size())
		var vp = get_tree().root.get_viewport()
		print("[Save] viewport: ", vp)
		var kmap_data: Dictionary = {}
		#if buildLayer.sw_circuit_analyzer:
			#kmap_data = buildLayer.sw_circuit_analyzer.get_karnaugh_map_data()
		var ok = SWSaveManager.save_builds(name, builds, vp, kmap_data)
		if ok:
			print("[Save] 存档成功: ", name)
		else:
			push_warning("[Save] 存档失败: " + name)
	)
	get_tree().paused = true
	get_tree().root.add_child(dialog)
	dialog.popup_centered()

func _on_load_requested() -> void:
	var dialog = preload("res://ui/sw_load_dialog.tscn").instantiate()
	dialog.load_confirmed.connect(func (name: String):
		var data = SWSaveManager.load_builds(name)
		if data.is_empty():
			push_warning("无法加载存档: " + name)
			get_tree().paused = false
			return
		buildLayer.load_save_data(data)
		print("加载存档成功: ", name)
		get_tree().paused = false
	)
	get_tree().paused = true
	get_tree().root.add_child(dialog)
	dialog.popup_centered()
