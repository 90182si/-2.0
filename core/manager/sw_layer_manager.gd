class_name SWLayerManager extends Node

#电路文件管理器：新建脚本的类名不在 headless 的全局类缓存里，一律走 preload
const CIR_MANAGER := preload("res://circuit/sw_cir_manager.gd")
#跨场景会话："当前是哪个存档"要跨场景活，场景切掉这一层的实例就没了
const SESSION := preload("res://core/manager/sw_session.gd")

#当前存档名：读档/存盘成功后更新，保存对话框用它回填。
#存在 SWSession 的静态变量里，所以另一套场景的管理器也看得到同一个值
var current_save_name: String:
	get:
		return SESSION.current_save_name
	set(value):
		SESSION.current_save_name = value

var layers:Array[SWLayer] = []
var hudLayer:SWHudLayer = null
var holdLayer:SWHoldLayer = null
var buildLayer:SWBuildLayer = null

#var mapSystem: SWMapLayerSystem = null
var hudSystem: SWHudLayerSystem = null
var holdSystem: SWHoldLayerSystem = null
var buildSystem: SWBuildLayerSystem = null

var _systemManager: SWSystemManager = null

#图层节点名 -> 图层系统：新场景加了别的图层（比如机器人场景的实体层）时，
#根节点靠名字取系统接信号，不用再往这里加字段
var systems_by_view: Dictionary = {}

func _ready() -> void:
	# 逐帧系统排在固定 tick（TickDriver.process_priority = -100）之后
	process_priority = 100
	var parent := get_parent()
	if parent != null:
		_systemManager = parent.get("system_manager") as SWSystemManager
		
	#只收自己这个场景下的图层：分屏调试时机器人场景与电路场景同时在树里，
	#直接 get_nodes_in_group 会把另一边的图层也收进来（build/entity 系统会被装配两遍）
	for node in SwCommon.GetNodesInGroupInScene(self, "SWLayer"):
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
		systems_by_view[view.name] = system
		if _systemManager != null:
			_systemManager.add_system(system)
		if system is SWHudLayerSystem:
			hudSystem = system
		elif system is SWHoldLayerSystem:
			holdSystem = system
		elif system is SWBuildLayerSystem:
			buildSystem = system
	for render_node:SWRenderNode in SwCommon.GetNodesInGroupInScene(self, "SWRender"):
		var render_system:SWRenderSystem = render_node.create_render_system()
		if render_system == null:
			continue
		render_system.attach_render_node(render_node)
		if _systemManager != null:
			_systemManager.add_system(render_system)
	_wire_systems()
			
func _exit_tree() -> void:
	#搬进分屏壳的左视口：节点还要继续用，而且重入树不会再走 _ready，
	#这里把系统表清掉就再也装不回来了
	if SESSION.relocating_scene:
		return
	if _systemManager != null:
		_systemManager.clear()
		_systemManager = null
	holdSystem = null
	buildSystem = null
	hudSystem = null
	systems_by_view.clear()

#按图层节点名取系统（取不到返回 null）
func get_layer_system(node_name: String) -> SWLayerSystem:
	return systems_by_view.get(node_name, null) as SWLayerSystem
	
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
		if hudSystem != null:
			#左键点到接口元件 → HUD 名称编辑面板
			buildSystem.edit_build_requested.connect(hudSystem.show_io_name_panel)
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
			#鼠标悬浮元件 → 右上角表达式面板
			holdSystem.hover_build_changed.connect(hudSystem.on_hover_build_changed)
		hudSystem.save_requested.connect(_on_save_requested)
		hudSystem.load_requested.connect(_on_load_requested)
		
func _on_save_requested() -> void:
	if buildSystem != null and buildSystem.is_job_running():
		buildSystem.notify_job_busy("任务进行中，请稍候再保存")
		return
	var dialog = preload("res://ui/sw_save_dialog.tscn").instantiate()
	#回填当前存档名：覆盖保存不用每次重新敲一遍
	dialog.call("set_default_name", current_save_name)
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
		#缩略图抓本层所在的视口：单场景时它就是根视口；分屏调试时本层在子视口里，
		#抓根视口会把右边的电路场景一起拍进去
		var vp = get_viewport()
		print("[Save] viewport: ", vp)
		var ok = SWSaveManager.save_builds(name, builds, vp, {})
		if ok:
			print("[Save] 存档成功: ", name)
			#存过一次就是当前存档，下次再存直接覆盖这个名字
			current_save_name = name
			#电路单独存同名 .swcir（机器人场景靠它加载）；没有接口电路时不生成文件
			var cir_path: String = CIR_MANAGER.export_all(name, builds)
			if cir_path != "":
				print("[Save] 电路文件: ", cir_path)
			#刚存过，文件已经是最新结构：退出时不用再整表导出一遍
			#（上万元件跑一趟网表生成不便宜，而这个标记只为「没存就退出」兜底）
			if SESSION.edited_save == name:
				SESSION.edited_save = ""
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
	await load_save_by_name(name)

#读档主流程：玩家点「加载」与机器人面板「修改电路」自动进电路场景都走这里。
#成功时记下存档名，之后保存对话框可以直接回填它
func load_save_by_name(name: String) -> bool:
	_show_progress("读取存档…")
	#让进度窗先画出来，再开始同步解析 JSON
	await get_tree().process_frame
	var data = SWSaveManager.load_builds(name)
	if data.is_empty():
		push_warning("无法加载存档: " + name)
		_hide_progress()
		get_tree().paused = false
		return false
	if buildSystem:
		await buildSystem.load_save_data_async(data, _update_progress)
	#恢复视口（缩放与偏移）
	var camera := get_viewport().get_camera_2d() as SWCamera2D
	SWSaveManager.apply_viewport(camera, data)
	#存档 JSON 树立即释放：几十 MB 的文本解析出来的 Dictionary/Array 树大概是它体积的
	#4~8 倍，而且里面有上万个嵌套 pos/state 子字典。建筑已经建完，留着只是白占内存。
	#协程局部变量会活到函数返回，这里显式清空让内存在玩家开局前就退回去。
	data.clear()
	#读档成功才算「当前存档」：失败时保留原来的名字，别把回填弄丢
	current_save_name = name
	#旧世界的结构改动跟着旧世界一起作废：不清的话退出时会拿新世界导出的结构
	#去覆盖另一次存档的电路文件
	SESSION.edited_save = ""
	_hide_progress()
	get_tree().paused = false
	print("加载存档成功: ", name)
	return true

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
