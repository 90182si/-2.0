class_name SWHudLayer extends SWLayer

signal selTool(buildDefine:SWBuildDefine)
signal save_requested()
signal load_requested()

const selToolPath:String = "res://res/"
var selTools:Array = []

func _ready() -> void:
	selTools = get_tree().get_nodes_in_group("SelTool")
	_apply_atlas()
	for tool:TextureButton in selTools:
		tool.pressed.connect(_on_sel_tool_pressed.bind(tool.name))
	var save_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/保存")
	if save_btn:
		save_btn.pressed.connect(_on_save_pressed)
	var load_btn = get_node_or_null("HBoxContainer/MarginContainer/MarginContainer/HBoxContainer/加载")
	if load_btn:
		load_btn.pressed.connect(_on_load_pressed)
	_build_job_panel()
	_build_expr_panel()

# ========== 左下角任务进度条（复制/剪切准备、放置队列） ==========
var _job_panel: Control = null
var _job_label: Label = null
var _job_bar: ProgressBar = null

func _build_job_panel() -> void:
	var panel := ColorRect.new()
	panel.color = Color(0.0, 0.0, 0.0, 0.55)
	# 纯展示，不能吃掉地图上的鼠标事件
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12
	panel.offset_top = -74
	panel.offset_right = 292
	panel.offset_bottom = -12
	panel.visible = false
	add_child(panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_job_label = Label.new()
	_job_label.text = ""
	box.add_child(_job_label)

	_job_bar = ProgressBar.new()
	_job_bar.show_percentage = false
	_job_bar.min_value = 0.0
	_job_bar.max_value = 1.0
	_job_bar.step = 0.001
	_job_bar.custom_minimum_size = Vector2(0, 14)
	box.add_child(_job_bar)
	_job_panel = panel

func show_job_progress(text: String, pct: float) -> void:
	if _job_panel == null:
		return
	_job_label.text = text
	_job_bar.value = clampf(pct, 0.0, 1.0)
	if not _job_panel.visible:
		_job_panel.visible = true

func hide_job_progress() -> void:
	if _job_panel != null:
		_job_panel.visible = false

func is_job_progress_visible() -> bool:
	return _job_panel != null and _job_panel.visible

# ========== 右上角悬浮表达式面板（鼠标停在元件上时显示它在算什么） ==========
# 表达式树是电路构建时递归建好的，这里只读出来排版（见 SWExprDescribe），不重建
const EXPR_DESCRIBE := preload("res://circuit/sw_expr_describe.gd")
var _expr_panel: Control = null
var _expr_label: Label = null
var _expr_build: SWBuildItemDefine = null
var _expr_text: String = ""

func _build_expr_panel() -> void:
	var panel := PanelContainer.new()
	# 纯展示，不能吃掉地图上的鼠标事件
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 贴右上角：左右都锚在右边，向左长；上下锚在顶部，向下长
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -352
	panel.offset_right = -12
	panel.offset_top = 12
	panel.offset_bottom = 12
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.62)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	panel.visible = false
	add_child(panel)

	_expr_label = Label.new()
	_expr_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 表达式会长，折行比横向撑爆屏幕好
	_expr_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_expr_label.custom_minimum_size = Vector2(320, 0)
	_expr_label.add_theme_font_size_override("font_size", 15)
	panel.add_child(_expr_label)
	_expr_panel = panel

# 表达式面板是否允许显示：与性能面板的「建筑信息」开关联动，
# 关掉建筑信息时右上角也不该再冒出一个同样面积的表达式面板
var expr_enabled:bool = true

func set_expr_enabled(enabled:bool) -> void:
	expr_enabled = enabled
	if not enabled:
		hide_build_expr()

# 悬浮到某个元件就显示它的表达式；build 为 null 表示鼠标离开，收面板
func show_build_expr(build: SWBuildItemDefine) -> void:
	if _expr_panel == null or not expr_enabled:
		return
	if build == null:
		hide_build_expr()
		return
	var text: String = EXPR_DESCRIBE.describe_build(build)
	if text.is_empty():
		hide_build_expr()
		return
	_expr_build = build
	_expr_text = text
	_expr_label.text = text
	_expr_panel.visible = true

func hide_build_expr() -> void:
	_expr_build = null
	_expr_text = ""
	if _expr_panel != null:
		_expr_panel.visible = false

func is_build_expr_visible() -> bool:
	return _expr_panel != null and _expr_panel.visible

func get_build_expr_text() -> String:
	return _expr_text

# 把 HUD 图标用的 AtlasTexture 切到全局选中的图集
func _apply_atlas() -> void:
	for tool in selTools:
		var resPath = selToolPath+tool.name+".tres"
		var buildDefine = load(resPath) as SWBuildDefine
		if not buildDefine:
			continue
		var btn := tool as TextureButton
		if btn == null:
			continue
		btn.set_texture_normal(buildDefine.atlasIcon)

func on_view_rect_changed(_viewRect:Rect2,_speedVec:Vector2) -> void:
	pass

func _on_sel_tool_pressed(extra_arg_0: String) -> void:
	var resPath = selToolPath+extra_arg_0+".tres"
	var buildDefine = load(resPath) as SWBuildDefine
	if buildDefine:
		selTool.emit(buildDefine)
	else:
		printerr(resPath,"不存在")

func _on_save_pressed() -> void:
	save_requested.emit()

func _on_load_pressed() -> void:
	load_requested.emit()

func create_layer_system() -> SWLayerSystem:
	return SWHudLayerSystem.new()
