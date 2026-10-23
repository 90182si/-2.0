class_name SWLayerManager extends Node

var layers:Array[SWLayer] = []
var hudLayer:SWHudLayer = null
var holdLayer:SWHoldLayer = null
var buildLayer:SWBuildLayer = null

#var mapSystem: SWMapLayerSystem = null
var hudSystem: SWHudLayerSystem = null
var holdSystem: SWHoldLayerSystem = null
var buildSystem: SWBuildLayerSystem = null

var _systemManager: SWSystemManager = null

func _ready() -> void:
	# 逐帧系统排在固定 tick（TickDriver.process_priority = -100）之后
	process_priority = 100
	var parent := get_parent()
	if parent != null:
		_systemManager = parent.get("system_manager") as SWSystemManager
		
	for node in get_tree().get_nodes_in_group("SWLayer"):
		var view := node as SWLayer
		if view == null:
			continue
		layers.append(view)
		if view is SWHudLayer:
			hudLayer = view
		elif view is SWHoldLayer:
			holdLayer = view
		elif view is SWBuildLayer:
			buildLayer = view

		var system := view.create_layer_system()
		if system == null:
			continue
		system.attach_view(view)
		if _systemManager != null:
			_systemManager.add_system(system)
		if system is SWHudLayerSystem:
			hudSystem = system
		elif system is SWHoldLayerSystem:
			holdSystem = system
		elif system is SWBuildLayerSystem:
			buildSystem = system
	_wire_systems()
			
func _exit_tree() -> void:
	if _systemManager != null:
		_systemManager.clear()
		_systemManager = null
	holdSystem = null
	buildSystem = null
	hudSystem = null
	
#设置信号
func _wire_systems() -> void:
	if buildSystem != null and holdSystem != null:
		buildSystem.set_hold_system(holdSystem)
		holdSystem.hold_idle_builds.connect(buildSystem.on_hold_idle_builds)
		holdSystem.hold_remove_builds.connect(buildSystem.on_hold_remove_builds)
		holdSystem.select_builds_by_rect.connect(buildSystem.on_select_by_rect)
		holdSystem.deselect_builds_by_rect.connect(buildSystem.on_deselect_by_rect)
		holdSystem.drag_started.connect(buildSystem.on_drag_started)
		holdSystem.drag_ended.connect(buildSystem.on_drag_ended)
		holdSystem.place_drag_ended.connect(buildSystem.on_place_drag_ended)
		holdSystem.erase_drag_ended.connect(buildSystem.on_erase_drag_ended)
	if hudSystem != null:
		if holdSystem != null:
			hudSystem.tool_selected.connect(holdSystem.set_hold_tool)
		hudSystem.save_requested.connect(_on_save_requested)
		hudSystem.load_requested.connect(_on_load_requested)

func _process(delta: float) -> void:
	if _systemManager:
		_systemManager.frame(delta)
		
func _on_save_requested() -> void:
	var dialog = preload("res://ui/sw_save_dialog.tscn").instantiate()
	dialog.save_confirmed.connect(func (name: String):
		print("[Save] 开始保存: ", name)
		if buildSystem == null:
			push_error("[Save] buildSystem 为 null!")
			return
		# 先隐藏对话框再截图
		dialog.visible = false
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var builds = buildSystem.build_manager.getAllBuilds()
		print("[Save] 获取到建筑物: ", builds.size())
		var vp = get_tree().root.get_viewport()
		print("[Save] viewport: ", vp)
		var ok = SWSaveManager.save_builds(name, builds, vp, {})
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
		if buildSystem:
			buildSystem.load_save_data(data)
		#恢复视口（缩放与偏移）
		var camera := get_viewport().get_camera_2d() as SWCamera2D
		SWSaveManager.apply_viewport(camera, data)
		print("加载存档成功: ", name)
		get_tree().paused = false
	)
	get_tree().paused = true
	get_tree().root.add_child(dialog)
	dialog.popup_centered()
