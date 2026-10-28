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
		
	for layer:SWLayer in get_tree().get_nodes_in_group("SWLayer"):
		var view := layer as SWLayer
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
	for render_node:SWRenderNode in get_tree().get_nodes_in_group("SWRender"):
		var render_system:SWRenderSystem = render_node.create_render_system()
		if render_system == null:
			continue
		render_system.attach_render_node(render_node)
		if _systemManager != null:
			_systemManager.add_system(render_system)
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
		#任务闸门：复制准备期间禁放置与擦除，放置任务期间只禁擦除
		holdSystem.set_edit_gates(
			Callable(buildSystem, "can_place"),
			Callable(buildSystem, "can_erase"))
		if hudLayer != null:
			buildSystem.set_hud_view(hudLayer)
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
			hudSystem.tool_selected.connect(func(build_define:SWBuildDefine) -> void:
				#准备手持期间换工具会被准备结果覆盖，直接忽略
				if buildSystem == null or not buildSystem.is_clipboard_busy():
					holdSystem.set_hold_tool(build_define)
			)
		hudSystem.save_requested.connect(_on_save_requested)
		hudSystem.load_requested.connect(_on_load_requested)
		
func _on_save_requested() -> void:
	if buildSystem != null and buildSystem.is_job_running():
		buildSystem.notify_job_busy("任务进行中，请稍候再保存")
		return
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
	#读档会清空世界并整表重建电路，后台任务跑到一半会让两边互相拆台
	if buildSystem != null and buildSystem.is_job_running():
		buildSystem.notify_job_busy("任务进行中，请稍候再加载")
		return
	var dialog = preload("res://ui/sw_load_dialog.tscn").instantiate()
	dialog.load_confirmed.connect(_on_load_confirmed)
	get_tree().paused = true
	get_tree().root.add_child(dialog)
	dialog.popup_centered()

func _on_load_confirmed(name: String) -> void:
	_show_progress("读取存档…")
	#让进度窗先画出来，再开始同步解析 JSON
	await get_tree().process_frame
	var data = SWSaveManager.load_builds(name)
	if data.is_empty():
		push_warning("无法加载存档: " + name)
		_hide_progress()
		get_tree().paused = false
		return
	if buildSystem:
		await buildSystem.load_save_data_async(data, _update_progress)
	#恢复视口（缩放与偏移）
	var camera := get_viewport().get_camera_2d() as SWCamera2D
	SWSaveManager.apply_viewport(camera, data)
	_hide_progress()
	get_tree().paused = false
	print("加载存档成功: ", name)

var _progress_win: Window = null
var _progress_label: Label = null
var _progress_bar: ProgressBar = null

func _show_progress(title_text: String) -> void:
	if _progress_win == null:
		var win := Window.new()
		#无边框+常驻处理：读档期间主树是暂停的，进度窗仍要能刷新
		win.borderless = true
		win.unresizable = true
		win.process_mode = Node.PROCESS_MODE_ALWAYS
		win.size = Vector2i(360, 92)
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 18
		box.offset_top = 18
		box.offset_right = -18
		box.offset_bottom = -18
		win.add_child(box)
		_progress_label = Label.new()
		box.add_child(_progress_label)
		_progress_bar = ProgressBar.new()
		_progress_bar.show_percentage = false
		_progress_bar.min_value = 0.0
		_progress_bar.max_value = 1.0
		_progress_bar.custom_minimum_size = Vector2(0, 18)
		box.add_child(_progress_bar)
		_progress_win = win
		get_tree().root.add_child(win)
	_progress_label.text = title_text
	_progress_bar.value = 0.0
	_progress_win.popup_centered()

func _update_progress(pct: float, text: String) -> void:
	if _progress_bar != null:
		_progress_bar.value = pct
	if _progress_label != null:
		_progress_label.text = text

func _hide_progress() -> void:
	if _progress_win != null:
		_progress_win.queue_free()
		_progress_win = null
		_progress_label = null
		_progress_bar = null
